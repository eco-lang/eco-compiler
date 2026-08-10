# Kernel Boundary Reduction

**Status: DRAFT v1 — 2026-08-09. Exploration document; nothing here is committed.**

**Provenance.** Produced from (a) an 8-agent classification audit of every exported
kernel symbol in `eco-kernel-cpp/`, `elm-kernel-cpp/` and the runtime support
surface — the per-symbol tables are checked in beside this document as
`design_docs/kernel-boundary/audit-0*.md`; (b) a static call-site census of the
self-compiled compiler (`build/compiler/build-kernel/bin/eco-compiler.mlir`,
972,418 ops — census data at
`design_docs/kernel-boundary/callsite-census-self-compile.txt`); (c) five
workflow-drafted, adversarially verified deep-dive sections (§3–§9 below).

## Executive summary

Five facts to retain:

1. **The census is extremely concentrated.** 17,005 static kernel occurrences
   (16,870 call forms after stubs/artifacts) in the self-compiled compiler
   across 130 kernel symbols; the top **2** cover
   44.8%, the top **10** cover 82.8%, the top **30** cover 95.2%. All 38 Basics
   and all 7 Bitwise symbols have **zero** occurrences — intrinsics already
   displaced them (9,013 `eco.int.*` ops in the same module). Displacement
   works; the census is the list of what hasn't been displaced yet (§3–§4).
2. **Only ~11 of 403 kernel symbols are effectful at call time.** Task-returning
   kernels are pure fixed-shape allocations under `KERNEL_TASK_IO_001`; Json
   decoders and Bytes encoders are description constructors. 97% of the surface
   is in principle visible to the optimizer (§2).
3. **The boundary is opaque for two removable reasons**: no LTO anywhere in the
   build, and kernel declarations carry zero attributes — exactly one symbol in
   the entire compiler has memory-effect attributes. Meanwhile 101 of 133
   dialect ops already carry `Pure`, and nothing harvests it: no MLIR CSE, no
   folders, and `eco.call` is trait-free (§1, §9).
4. **The single biggest conversion is `List.cons` → `eco.construct.list`**:
   25.5% of all kernel call forms, and both the op and its zero-call inline
   lowering already exist and run at higher volume than the sites being
   converted. The missing piece is a `"List"` arm in `kernelIntrinsic` plus one
   named trap (`EcoListTemplate` hint handling) (§4). The Scheduler Task
   constructors (17.1% of call forms) are the biggest *new-op* prize (§5).
5. **Kernel poison caps shipped optimizations today**: gc-free propagation
   (default-ON) reaches only 5.27% of functions — worth −1.72% mean wall at
   that coverage — because any kernel call poisons its whole transitive caller
   chain; borrow inference reports 26,988 kernel-poisoned args. The cheapest
   attack is a per-kernel facts table (extending `KernelSigs`) reflected as
   `gc-leaf-function` on the ~15 provably non-allocating hot kernels (§6, §8).
   Rows 1–2 of the §8 poisoning inventory carry measured numbers; rows 3–6
   are unmeasured pending the census work (§8 A.2, plans/kernel-call-census.md).

Section map: §1 problem · §2 classification · §3 census · §4 existing-op
conversions · §5 new sub-dialects · §6 attribute modelling · §7 wholesale
re-implementations · §8 poisoning inventory · §9 Pure-trait harvesting (ends with
the sequenced roadmap) · Appendices A (evidence) / B (correctness backlog) /
C (related documents).

---

## 1. The problem

Eco compiles Elm to MLIR (`eco` dialect) and lowers through LLVM, but every call
to a C++ kernel function crosses an **opaque boundary** that the optimizer cannot
see through. Two structural facts make the boundary maximally opaque today:

1. **There is no LTO anywhere in the build.** Kernels are plain static archives
   (`elm-kernel-cpp/CMakeLists.txt`, `eco-kernel-cpp/CMakeLists.txt`; zero hits
   for `-flto`/`ThinLTO`/`INTERPROCEDURAL_OPTIMIZATION` repo-wide). Kernel bodies
   are invisible to LLVM at every point in the pipeline — even though they are
   C++ that LLVM itself compiled.
2. **Kernel declarations carry no attributes.** `KernelFuncOpLowering`
   (`runtime/src/codegen/Passes/EcoToLLVMFunc.cpp:80-95`) emits each
   `Elm_Kernel_*`/`Eco_Kernel_*` declaration with only `Linkage::External` — no
   `memory(...)`, no `nounwind`, no `willreturn`, no `gc-leaf-function`. Exactly
   one symbol in the whole compiler carries memory-effect attributes
   (`eco_bump_state`, `EcoBackend.cpp:1015-1019`). LLVM must assume every kernel
   call reads and writes all memory, may throw, may not return, and may collect.

The cost of one opaque call is not just a `call` instruction. It is:

- a **GC statepoint**: `EcoGCPrepare` classifies every `eco.call` as a call
  safepoint and appends the full live-root set as SSA operands
  (`EcoGCPrepare.cpp:125-140`, `EcoOps.cpp:989-1005`); RS4GC then spills and
  reloads every live heap pointer around the call;
- an **allocation-group barrier**: `isGroupBarrier`
  (`EcoGCPrepare.cpp:110-121`) splits HEAP_034 coalesced bump-allocation runs at
  every call, doubling capacity checks;
- **transitive gc-free poison**: `propagateGcFreeLeafAttrs`
  (`EcoBackend.cpp:1611-1726`, default-ON) poisons every transitive caller of a
  non-gc-leaf declaration — one `String.length` call disqualifies its entire
  caller chain from statepoint elision (CGEN_072);
- **borrow-inference poison**: unlisted kernels force all-owned argument
  assumptions (`Borrow/Constrain.elm:883-900`), measured at 26,988 poisoned heap
  args (`design_docs/borrow-inf-census.md:503`);
- an **optimization fence** at every level: no inlining (no body), no CSE (no
  purity metadata), no constant folding, no DCE of unused results.

Meanwhile the `eco` dialect already models purity — **101 of 133 ops in
`Ops.td` carry the `Pure` trait** — but `eco.call` carries none, and nothing in
the pipeline harvests the traits that exist (no MLIR CSE pass, no folders, no
canonicalizer).

The strategy of this document: **classify the kernel surface honestly, convert
what should be dialect ops, model attributes for what stays C++, and add the
passes that harvest the resulting knowledge.** The existence proof that this
works is already in-tree twice: compiler intrinsics displaced *all* Basics and
Bitwise kernels (zero surviving call sites — §3), and the BF dialect displaced
the Bytes hot path with 27 typed ops carrying declared memory effects — the only
kernel family that fuses.

## 2. Classification of the kernel surface

The audit classified all **403 declared kernel symbols** (336 `Elm_Kernel_*` +
54 `Eco_Kernel_*` + runtime-facing helpers) by what they actually do at call
time. Full per-symbol tables: `audit-01` … `audit-06`.

| Class | Count | Meaning |
|---|---:|---|
| **Pure** (P / PA / PH) | ~260 (65%) | No IO, no observable state. Most allocate on the GC heap (PA); some only read heap structure (PH); a few touch neither (P). |
| **Task builders** (TB) | ~56 (14%) | Allocate a heap value *describing* IO; perform none at call time. |
| **Runtime state** (RT) | ~15 | Mutate runtime-internal registries (effect managers, GC roots, ports). No external IO. |
| **Effectful at call time** (E/X) | **~11 (2.7%)** | Real IO, clock/DOM access, or termination. |
| **Stubs** | ~62 | Browser/VirtualDom/File-upload surface; unimplemented. |

Three consequences frame everything that follows:

**2.1 "Effectful" kernels are almost all pure constructors.** The premise that a
Task-returning kernel merely *requests* IO is not just intuition here — it is an
enforced invariant. `KERNEL_TASK_IO_001` (`design_docs/invariants.csv`) requires
every Task-returning C++ symbol to perform its IO inside a `Task_Binding`
callback stepped by the scheduler, never at kernel-call time. In
`eco-kernel-cpp/`, 47 of 53 symbols (89%) comply; the six that fire at call time
are the invariant's named exemptions. The real IO lives in *binding-body*
statics (`writeStringBody`, `waitBody`, …) that are not kernel exports at all.
A Task builder is, precisely, a pure fixed-shape 3-object allocation
(`runtime/src/platform/TaskBinding.hpp:144-162`) — which is why §5 can propose
constructing Tasks inline.

The audit found exactly two violations, both in `PlatformRuntime.cpp`
(`sendToSelf` at `:574`, `sendToApp` at `:549`) — they perform the send at
construction time. Both are the same bug class fixed for `spawn`/`kill` on
2026-07-23. Fix independently of this design (correctness backlog, Appendix B).

**2.2 The same split recurs inside "pure" modules.** Json decoders and Bytes
encoders are *descriptions* (one tagged allocation each — 33 of 35 Json exports,
10 of 26 Bytes exports); only `run`/`runOnString`/`encode`/`decode` interpret
them. Description-constructors are trivially convertible (§4); interpreters are
attribute-modelling targets (§6) or re-implementation targets (§7).

**2.3 The genuinely effectful core is tiny.** Eleven symbols perform IO at call
time. Everything else — 97% of the surface — is in principle visible to the
optimizer, if we give the compiler the means to see it.

---

## 3. The census (Q1–Q2: what actually crosses the kernel boundary today?)

### Corpus and methodology

The primary corpus is the textual MLIR of the self-compiled compiler
(`eco-compiler.txt.mlir`, 84 MB, 68,996 `func.func`s — the standard benchmark
workload). `kernel-callsites.txt` counts every textual occurrence of each
`@Elm_Kernel_*` / `@Eco_Kernel_*` symbol in that module: **17,005 occurrences
across 133 rows**. Three rows are census-tooling artifacts, not kernel
symbols: `@Eco_Runtime_random_`/`_dirname_`/`_saveState_` are `$`-truncated
names of ordinary compiled `Eco.Runtime` functions (5 occurrences — 2 calls +
3 plain `func.func` definitions, no `is_kernel` stub). Each of the remaining
**130 kernel symbols** contributes exactly one `func.func private …
is_kernel = true` stub definition (exactly 130 such stubs in the module; e.g.
`eco-compiler.txt.mlir:972180` for `List_cons`), so the number of kernel
*call forms* is 17,000 − 130 = **16,870**, split
between direct applied calls (`"eco.call" … callee = @Sym`) and first-class
captures (`"eco.papCreate" … function = @Sym`). Both splits below were
recomputed directly from the module; per-symbol they reconcile exactly
(`direct + pap + 1 stub = census count` for every kernel row checked).

**Denominator convention:** unless a passage says "call forms", every
percentage in this document is over the 17,005 raw occurrences; the
call-form denominator (16,870) shifts no rank and no percentage by more
than 0.3 points.

Caveats that bound what this census can tell us:

- **(a) Static, not dynamic.** These are static call sites in one workload, not
  execution counts. This repo's repeated finding is that static censuses
  mislead — the TIER pattern is ×4+ collapses of static-census-justified
  optimizations at admissibility gates, and wall tracks *retention and deleted
  per-op work*, not site or allocation counts (memory: eco-opt-tier-roadmap;
  K6/K5 in mono comparable-key outcome). Treat ranks as a prioritization
  heuristic, not a wall forecast.
- **(b) The census counts what SURVIVES intrinsic lowering — and that is the
  existence proof for this whole strategy.** All 38 Basics and all 7 Bitwise
  symbols have **zero** occurrences (verified: `grep -c Basics|Bitwise` over the
  census = 0/0), because `kernelIntrinsic`
  (compiler/src/Compiler/Generate/MLIR/Intrinsics.elm:312-334) is consulted
  *before* any kernel call is emitted at applied sites
  (compiler/src/Compiler/Generate/MLIR/Expr.elm:4199) and displaced them with
  dialect ops: the same module contains **9,013 `eco.int.*` ops** (grep of the
  module; `eco.int.add` alone is 2,435). Displacement works; the census is the
  list of what has not been displaced yet.
- **(c) Second corpus.** Report 01 ran a complementary exhaustive grep over all
  **990 generated `.mlir` files** under `/work/build` (self-compile stages + the
  full E2E corpus; file count re-verified). Its top lines — `Utils_append`
  13,660, `Utils_equal` 5,183, `Utils_compare` 1,208, `Utils_lt` 324,
  `Utils_notEqual` 250, `Utils_gt` 164, `Char_toLower` 16, `Utils_ge` 12
  (kernel-review/01-basics-bitwise-char-utils.md, "Liveness evidence") — agree
  with the ranking here. Symbol-deletion decisions must be made against that
  corpus, not this one.
- **(d) The census undercounts lowering-synthesized calls.** The dump is
  pre-pipeline (0 `eco_scratch_*` markers in it); string-pattern `case`
  lowering *synthesizes additional* `Elm_Kernel_Utils_equal` calls later
  (runtime/src/codegen/Passes/EcoToLLVMControlFlow.cpp:353-357), so the shipped
  binary calls `Utils_equal` from more places than the 1,356 sites counted.
- **(e) Dynamic census — EXECUTED 2026-08-09** (plans/kernel-call-census.md;
  raw data `kernel-boundary/kernel-census-dynamic-stage7a.txt`). Stage 7a
  executes **3,676,097,627 kernel calls across 98 symbols**, and the static
  ranks lie exactly as feared: `Utils_compare` is **53.2% of all dynamic
  kernel calls** (1.95B; static rank #11), and with its 3-per-intrinsic
  `getOrder` singleton loads (881M) the comparison machinery alone is **77%
  of dynamic kernel traffic** — Dict/`Data.Map` key comparison is the
  compiler's kernel workload. `List_cons` is 5.2% dynamic (static 24.5%);
  the Scheduler/Task+IO surface is **0.0015%** (the compiler's own IO monad
  bypasses elm Tasks — §5's task op is user-program work, not compiler wall);
  `String_uncons`/`String_slice`/`String_join` are dynamically hot from ≤73
  static sites. A 20-kernel gc-leaf pilot (audited set, env-gated in-tree)
  lifted gc-free coverage 5.27%→5.60% of functions (+1,929 de-statepointed
  sites, +17.3%) and shrank the binary −1.01% (−638KB of it stackmaps) —
  and was **wall-FLAT** on Stage 7a despite covering 64.1% of dynamic kernel
  calls: statepoint elision around kernel calls buys size and enabling
  effects, not direct wall. Original recommendation kept below for
  provenance: Before any Large-effort spend on a
  mid-table symbol, run a dynamic census (perf sampling, or a per-symbol
  counter in the kernel prologues analogous to the `eco_g_cons_sites` tally
  that already exists on the cons path, runtime/src/allocator/HeapHelpers.hpp:630-646).
  Static rank ≠ heat; this repo has paid for that lesson repeatedly.

### Top 10 symbols

Counts are raw census rows (each includes its 1 stub); `direct`/`pap` are the
recomputed call forms; cumulative % is over the 17,005 raw total.

| # | Symbol | census | direct `eco.call` | `papCreate` | cum % |
|---|---|---:|---:|---:|---:|
| 1 | `Elm_Kernel_List_cons` | 4,158 | 4,157 | 0 | 24.45% |
| 2 | `Elm_Kernel_Utils_append` | 3,465 | 3,464 | 0 | 44.83% |
| 3 | `Elm_Kernel_Scheduler_andThen` | 1,634 | 1,633 | 0 | 54.44% |
| 4 | `Elm_Kernel_Utils_equal` | 1,357 | 1,356 | 0 | 62.42% |
| 5 | `Elm_Kernel_Scheduler_succeed` | 999 | 998 | 0 | 68.29% |
| 6 | `Elm_Kernel_Bytes_getStringWidth` | 697 | 696 | 0 | 72.39% |
| 7 | `Eco_Kernel_Crash_crash` | 527 | 513 | 13 | 75.49% |
| 8 | `Elm_Kernel_List_reverse` | 469 | 468 | 0 | 78.25% |
| 9 | `Elm_Kernel_Bytes_read_u32` | 411 | **0** | **410** | 80.66% |
| 10 | `Elm_Kernel_JsArray_foldl` | 365 | 364 | 0 | 82.81% |

Two symbols cover 44.8%; ten cover 82.8%. The head of this distribution is
extremely concentrated.

### The 95% set

29 symbols reach 94.95% — just short. The minimal prefix covering ≥95% is the
**top 30**, through `Elm_Kernel_String_startsWith`, at **95.24%** of raw
occurrences (16,165 of 16,870 actual call forms = 95.82%). Rows 11–30:

| # | Symbol | census | direct | pap | cum % |
|---|---|---:|---:|---:|---:|
| 11 | `Elm_Kernel_Utils_compare` | 296 | 295 | 0 | 84.55% |
| 12 | `Elm_Kernel_List_map2` | 252 | 251 | 0 | 86.03% |
| 13 | `Elm_Kernel_Scheduler_fail` | 168 | 167 | 0 | 87.02% |
| 14 | `Elm_Kernel_Bytes_decodeFailure` | 152 | **0** | **151** | 87.92% |
| 15 | `Elm_Kernel_JsArray_initializeFromList_Int` | 118 | 117 | 0 | 88.61% |
| 16 | `Elm_Kernel_Scheduler_onError` | 113 | 112 | 0 | 89.27% |
| 17 | `Elm_Kernel_String_length` | 102 | 101 | 0 | 89.87% |
| 18 | `Elm_Kernel_JsArray_initialize_Int` | 97 | 96 | 0 | 90.44% |
| 19 | `Elm_Kernel_List_cons_Int` | 92 | 91 | 0 | 90.99% |
| 20 | `Elm_Kernel_List_sortBy` | 89 | 88 | 0 | 91.51% |
| 21 | `Elm_Kernel_Utils_lt` | 80 | 79 | 0 | 91.98% |
| 22 | `Eco_Kernel_MVar_put` | 79 | 78 | 0 | 92.44% |
| 23 | `Elm_Kernel_String_slice` | 73 | 72 | 0 | 92.87% |
| 24 | `Elm_Kernel_String_cons` | 69 | 68 | 0 | 93.28% |
| 25 | `Elm_Kernel_JsArray_empty` | 68 | 67 | 0 | 93.68% |
| 26 | `Elm_Kernel_Utils_notEqual` | 63 | 62 | 0 | 94.05% |
| 27 | `Elm_Kernel_List_cons_Char` | 56 | 55 | 0 | 94.38% |
| 28 | `Elm_Kernel_JsArray_foldr` | 49 | 48 | 0 | 94.67% |
| 29 | `Eco_Kernel_MVar_read` | 49 | 48 | 0 | 94.95% |
| 30 | `Elm_Kernel_String_startsWith` | 48 | 47 | 0 | 95.24% |

The remaining 100 kernel symbols share 705 call forms (4.2%; the 3
census-artifact rows above account for the rest); 76 of them have fewer
than 10 occurrences each, and 17 of the 21 `Eco_Kernel_File_*` symbols have
exactly 1 call site (the exceptions: `fileExists` 30, `dirExists` 12,
`findExecutable` 7, `appDataDir` 3).

### Direct vs PAP-capture, and why it changes conversion strategy

27 of the top 30 are ≥97% direct calls. The three exceptions matter:

- **`Bytes_read_u32` is 0 direct / 410 PAP**, and `Bytes_decodeFailure` is
  0 / 151. The reason is structural: `Bytes.Decode` *stores the kernel as a
  closure inside the `Decoder` value* — `unsignedInt32 endianness = Decoder
  (Elm.Kernel.Bytes.read_u32 (endianness == LE))`
  (~/.eco/0.1.0/packages/elm/bytes/1.0.8/src/Bytes/Decode.elm:80-105 shows the
  whole family) — and the C++ interpreter `Bytes_decode` applies it later.
- **`Crash_crash` has 13 PAP captures** (crash passed as a continuation)
  alongside its 513 direct calls.

**What PAP-only means:** the intrinsic mechanism fires only at *applied* call
sites (Expr.elm:4199 consults `kernelIntrinsic` when generating a saturated
`MonoCall`); a `papCreate` referencing the symbol keeps the extern alive no
matter how good the intrinsic is. So for any symbol with nonzero PAP count,
conversion has exactly three options: (1) keep the C++ symbol forever as the
closure target (intrinsics displace only the direct sites); (2) implement
**kernel-closure-lookthrough** (design_docs/kernel-closure-lookthrough.md — a
sketched MLIR pass that rewrites provably-kernel closures back into direct
calls at their application sites); or (3) move the capturing code itself to Elm
source so the capture is of an Elm function. Corollary, stated as policy: **a
kernel symbol is deletable only when its direct AND papCreate counts are zero
across the full 990-file corpus**, not merely absent from applied paths.

---

## 4. Conversions to EXISTING dialect ops (Q3)

The dialect ops that already exist are not hypothetical — this same module
already contains **13,451 `eco.construct.list`** and **50,396
`eco.construct.custom`** ops (grep of the module), all flowing through the
HEAP_034 inline-nursery lowering. Every conversion in this section reuses a
lowering that is already exercised at higher volume than the sites being
converted.

### Disposition of the top-30 (plus the Json constructor family)

Legend: **CONVERT-EXISTING** = an eco dialect op already does this;
**NEW-OP** = needs a new op, deferred to the sub-dialect section;
**ELM-SOURCE** = rewrite the kernel in Elm, deferred to §5b;
**ATTRIBUTE-ONLY** = keep the call, declare facts about it (deferred to the
attribute-modelling section); **STAYS** = irreducible C++ for now.

| Symbol (sites) | Disposition | Existing op / evidence |
|---|---|---|
| `List_cons` (4,157) + `_Int` (91) + `_Char` (55) | **CONVERT-EXISTING** | `eco.construct.list` (Ops.td:614) — §below |
| `Utils_append` (3,464) | NEW-OP | no string/list append op exists (Ops.td string section = 3 ops); split `eco.string.append` + `eco.list.append`, deferred |
| `Scheduler_andThen` (1,633), `succeed` (998), `fail` (167), `onError` (112) | NEW-OP / ELM-SOURCE (§5b) | 1-alloc Task ctors (runtime/src/platform/Scheduler.cpp:123-157) — but **not** `eco.construct.custom`: they allocate `Tag_Task` (allocTask, runtime/src/allocator/HeapHelpers.hpp:2015-2037; Heap.hpp:90), a dedicated 4-field-plus-`ctor`/`id` layout; HEAP_015's tag/layout-match rule (invariants.csv:400) rules out building them with a Custom-tag op |
| `Bytes_getStringWidth` (696) | ATTRIBUTE-ONLY now, NEW-OP later | no GC allocation of its own (report 04 table; O(1) UTF-8 arm) |
| `Crash_crash` (513 + 13 pap) | **CONVERT-EXISTING** | `eco.crash` (Ops.td:478) — §below |
| `List_reverse` (468) | ELM-SOURCE (§5b) | report 03 #10: `EcoListTemplate` reproduces the chunk win for `reverse = foldl cons []` |
| `Bytes_read_u32` (410 pap) | STAYS | PAP-only; fused path already covered by BF dialect (`bf.read.*`); direct-path displacement needs closure-lookthrough |
| `JsArray_foldl` (364), `foldr` (48), `map` (30), `indexedMap_Int` (21), `initialize_Int` (96), `initializeFromList_Int` (117) | ELM-SOURCE (§5b) | the HOF/init residue of JsArray — report 03 #12/#15 |
| `Utils_compare` (295), `lt` (79), `notEqual` (62), `equal` (1,356) | STAYS core + ATTRIBUTE-ONLY (+ NEW-OP sliver) | primitive cases are already intrinsics (`utilsIntrinsic`, Intrinsics.elm:557-646; `eco.{int,float,char}.{eq,ne,lt,le,gt,ge,cmp_order}` lower inline, EcoToLLVMArith.cpp) — only **boxed structural roots** survive in the census; none of them GC-allocates (report 01 table: compare returns pre-rooted Order singletons), which is the attribute story; `eco.string.eq`/`cmp_order` sliver deferred to sub-dialect section |
| `List_map2` (251), `sortBy` (88) | ELM-SOURCE (§5b) | report 03 #12/#13 |
| `Bytes_decodeFailure` (151 pap) | STAYS | PAP-only constant-returning closure inside the Decoder interpreter |
| `String_length` (101) | NEW-OP | `eco.string.length` does not exist; exact analogue of the inline `ArrayLengthOpLowering` (EcoToLLVMHeap.cpp:1219) per report 02 |
| `MVar_put` (78), `MVar_read` (48) | STAYS (as *called symbols*, short-term) | Task builders under KERNEL_TASK_IO_001 (invariants.csv:590); §5 R6's binding-builder shape would eventually inline their construction |
| `String_slice` (72) | STAYS (sliver NEW-OP later) | 6-representation dispatch + tiny-copy regime (report 02) |
| `String_cons` (68) | ELM-SOURCE (§5b) | semantically `String.fromChar c ++ str` (report 02) |
| `JsArray_empty` (67), `singleton` (39, rank 32) | **CONVERT-EXISTING** (emission gap) | `eco.array.empty` / `eco.array.singleton` exist (Ops.td:1017/1028) — §below |
| `String_startsWith` (47) | ATTRIBUTE-ONLY | zero allocation on any path (report 02); pure gc-leaf candidate |
| ~30 `Json_decode*`/`Json_map*`/`Json_wrap*`/`ENC_*` ctors (28 sites in this corpus) | **CONVERT-EXISTING** | `eco.construct.custom` (Ops.td:873) — §below |

### CONVERT-EXISTING #1: the cons family → `eco.construct.list` (4,303 direct sites, 25.5% of all kernel call forms)

**Why the gap exists.** `::` is an operator *imported from `List`*
(compiler/src/Compiler/Elm/Compiler/Imports.elm:34), so every `x :: xs` in Elm
source becomes a `List.cons` kernel call — and `kernelIntrinsic`
(Intrinsics.elm:312-334) dispatches on `Basics`/`Bitwise`/`Utils`/`JsArray`/
`Char`/`String` only: **there is no `"List"` arm at all** (confirmed also by
design_docs/theory/intrinsics_theory.md:260). `eco.construct.list` is emitted
solely for list *literals* `[a,b,c]` (Expr.elm:986, the two
`Ops.ecoConstructList` sites at :1017/:1031). LSS devirtualizes cons through
the one-entry kernel whitelist (`kernelDevirtArity`,
compiler/src/Compiler/MonoSolver/Translate.elm:1860-1866) straight into the
opaque extern.

**What the op already provides.** `Eco_ListConstructOp` (Ops.td:614) is
`[Pure]` + GCRootCarrier, carries `head_unboxed`/2-bit `head_kind` exactly
matching the kernel's `_Int`/`_Float`/`_Char` axis, and its lowering
(`ListConstructOpLowering`, EcoToLLVMHeap.cpp:418-457) emits the HEAP_034
(invariants.csv:572) inline nursery bump: composed header + two fresh field
stores, **zero runtime calls on the fast path**. The C++ path per cell instead
pays HPtr encode/decode, the `eco_g_cons_sites` tally branch, a roots
`memcpy`, a statepointed `eco_alloc_with_roots` call, and readback
(HeapHelpers.hpp:630-646) — and, being an attribute-free extern declaration,
poisons GC-freeness of every transitive caller (CGEN_072, invariants.csv:636)
and borrow inference (`List.cons` = 4,151 of the 26,988 poisoned args — the
pre-B3-KernelSigs snapshot, as are all poisoned-arg figures outside §8 row 4,
design_docs/borrow-inf-census.md:503, :845-870).

**The compiler-side change is small**: a `"List"` arm in `kernelIntrinsic`
returning a construct-list intrinsic, reusing the existing head-kind
derivation (KernelAbi.elm:310-317 already maps `MInt`/`MFloat`/`MChar` heads
to the `_Int`/`_Float`/`_Char` variants) and the existing devirt shape guard
(`kernelDevirtShapeOk`, Translate.elm:1882-1890, already proves tail/result
are boxed).

**The named trap — `EcoListTemplate`.** The Tier-B cons-accumulator →
scratch-chunk rewrite currently matches *both* link forms: kernel-cons calls
(`kernelConsKind`, runtime/src/codegen/Passes/EcoListTemplate.cpp:97-112) and
`eco.construct.list` — but the latter **only when it carries no live-root
hints** (`getLiveRoots().empty()`, EcoListTemplate.cpp:147-149; hinted ops
bail at :176-180 via `wcConsRoots`). Today's literal-only construct.list ops
are emitted *with* hints (`emitSafepointHints` = all live `!eco.value` vars,
Expr.elm:113-115, attached at :1017/:1031). A naive conversion that emits
hinted construct.list at every former cons site would therefore silently
disable the chunk rewrite (582 `eco_scratch_push_boxed` + 491
`eco_scratch_mark` sites in the self-compile per report 03 #4) — a regression
that no test would catch, only the chunking counters. The design must choose
one of:

1. **Emit hint-free** at converted cons sites and rely on `EcoGCPrepare`'s own
   liveness (it computes full live-root sets itself and refuses to shrink,
   EcoGCPrepare.cpp:315-351) — requires confirming the Elm-side hints are
   belt-and-braces rather than load-bearing for cross-block liveness; or
2. **Teach `EcoListTemplate` to accept hinted construct.list** (strip the
   hints when absorbing the link into the template), a ~20-line relaxation
   of the :147 condition.

Either way, the acceptance gate is the pass's own statistics: scratch-site
count must not drop versus baseline.

### CONVERT-EXISTING #2: `Crash_crash` → `eco.crash` (513 direct sites)

`eco.crash` exists (Ops.td:478, a `[Terminator]`), lowers to a call to
`eco_crash` + `llvm.unreachable` (`CrashOpLowering`,
runtime/src/codegen/Passes/EcoToLLVMErrorDebug.cpp:144-161), and `eco_crash`
is already declared **gc-leaf** (EcoToLLVMRuntime.cpp:845-849) — yet the
compiler never emits it: the op count in the self-compiled module is **zero**
(it appears only in hand-written codegen fixtures, test/codegen/crash*.mlir).
All 513 crash sites are ordinary value-position `eco.call`s — 491 feed their
phantom result straight to an `eco.yield`/`eco.return`, the other 22 feed an
`eco.unbox` (i64/i16) of it first (recounted in the module) — i.e.
maximally-effectful, may-return, statepointed calls into an attribute-free
extern.

Two deltas must be handled:

- **Behavior**: `Eco_Kernel_Crash_crash` → `Crash::crash`
  (eco-kernel-cpp/src/eco/Crash.cpp:20-33) prints `"Eco crash: …"` **plus a
  backtrace** (Crash.cpp:23-29) before `exit(1)`; `eco_crash`
  (runtime/src/allocator/RuntimeExports.cpp:2788-2807) prints
  `"Elm runtime error: …"` with **no backtrace**. Fold the backtrace dump and
  message parity into `eco_crash` first, as a standalone C++ change, so the
  conversion is behavior-preserving.
- **Structure**: `eco.crash` is a terminator with no result, while today's
  sites sit in value position inside `eco.case` alternatives. The emitter
  (or a small pre-SCF rewrite) must end the enclosing region at the crash
  instead of yielding the call's phantom result — this is region surgery, not
  a symbol swap, and is the real cost of the conversion.

The payoff is threefold: the call becomes gc-leaf (no statepoint, no stackmap
entry at 513 sites), `unreachable` gives LLVM the noreturn fact it currently
cannot see (§B.1 of report 08: kernel declarations carry no attributes at
all), and `Crash.crash` stops being a GC-freeness poison source (it is 461 of
the borrow census's poisoned-arg histogram,
design_docs/borrow-inf-census.md:845-870). If the region surgery is deemed too
expensive for the first pass, the fallback is ATTRIBUTE-ONLY: stamp the
`Eco_Kernel_Crash_crash` declaration itself gc-leaf + noreturn (noreturn under
§6.C's post-RS4GC one-rule policy) — sound because
`Crash::crash` provably never allocates on the GC heap and never returns.

### CONVERT-EXISTING #3: the Json constructor family → `eco.construct.custom` (~30 symbols)

Verified against elm-kernel-cpp/src/json/JsonExports.cpp: every decoder
constructor is literally one allocation plus ctor/field stores — `makeDecoder0/
1/1i/2/2ip` (JsonExports.cpp:464-539) are `eco_alloc_with_roots(Tag_Custom,
size, roots, n, mask)` + `dec->ctor = DEC_*` + field stores, and
`buildMapDecoder` (:1456) generalizes to `map2..map8`. That is *exactly* the
semantics of `eco.construct.custom` (Ops.td:873: Custom tag, ctor
discriminant, 2-bit-per-slot unboxed bitmap, GC live roots appended by
EcoGCPrepare). The encoder side (`Json_wrap_Int/Float`, `encodeNull`,
`emptyArray`, `emptyObject`, `addField`) has the same shape; `Json_addField`
is `eco.construct.tuple2` + `eco.construct.list` + `eco.construct.custom`.

**The one hazard is ctor-id coupling.** The compiler would hard-code ctor
indices that must match the C++ interpreter's constants (`DEC_STRING = 0` …
`DEC_MAP8 = 22`, JsonExports.cpp:57-79), because `Json_run`'s `runDecoder`
still dispatches on them. This contract is already shipping elsewhere:
`Bytes.Encode.Encoder` is a real Elm ADT
(~/.eco/…/bytes/1.0.8/src/Bytes/Encode.elm:46-57) whose compiler-assigned ctor
ids are pinned by the C++ `EncoderTag` enum in declaration order
(BytesExports.cpp:93-104) — proven, but unenforced by any test. A golden test
pinning both id tables is a precondition (report 04 #6).

**Honest impact accounting:** in *this* corpus the entire Json family is 37 raw
occurrences = 28 call forms across 9 symbols (census: `Json_wrap` 11,
`Json_encode` 4, … `Json_encodeNull` 2) —
the self-hosting compiler barely touches Json. The conversion is worth doing
because it is near-zero risk, deletes ~30 opaque symbols from the surface, and
its beneficiaries are user programs (ports, flags, HTTP payloads) and the E2E
corpus, not the benchmark. Do not book wall savings from it.

### Already done — and the proof it sticks: JsArray

Re-verified from the census: **`JsArray_length`, `unsafeGet`, `unsafeSet`,
`push`, `slice`, `appendN` and all their `_Int`/`_Float`/`_Char` variants are
completely absent from the self-compiled module** (no call, no papCreate, not
even a stub — 0 census rows match `unsafeGet|unsafeSet`), because
`jsArrayIntrinsic` (Intrinsics.elm:671-751) displaces them with
`eco.array.get/set/length/push/slice/append_n` (`ArrayLengthOpLowering` /
`ArrayGetOpLowering` fully inline at EcoToLLVMHeap.cpp:1219/1256;
`ArraySetOpLowering` at :1308 is a clone call + inline store). The module
contains 188 `eco.array.get`, 184 `eco.array.length`, 138 `eco.array.set`.
Report 03's claim of 18 dead-on-direct-path JsArray symbols holds (the 15
enumerated above plus the typed `singleton_Int`/`_Float`/`_Char` variants,
also absent — only the boxed `singleton` survives). What
survives is exactly the HOF/init residue (`foldl`/`foldr`/`map`/
`indexedMap_Int`/`initialize_Int`/`initializeFromList_Int` — ELM-SOURCE
territory) **plus an emission gap**: `JsArray_empty` (67) and
`JsArray_singleton` (39) still have kernel call sites even though
`eco.array.empty`/`eco.array.singleton` exist (Ops.td:1017/1028) — the module
has exactly **1** of each op. The surviving `empty` sites are nullary calls
inside per-spec CAF-memo thunks (`func.func … @Elm_JsArray_empty_$_349 …
{eco.caf_memo} { %0 = "eco.call"() @Elm_Kernel_JsArray_empty }` in the
module), a path that never consults `kernelIntrinsic`; the surviving
`singleton` sites are boxed-element calls whose result type does not match the
intrinsic's `arrayElementType` pattern (Intrinsics.elm:661-668). Closing this
is emission-side work only; wall impact is ~nil (CAF-memoized, evaluated once)
— it is surface hygiene.

`String_fromNumber_Int`/`_Float` are the same story one step further along:
zero census rows (fully displaced by `stringIntrinsic`, Intrinsics.elm:648-658
→ `eco.string.from_int`/`from_float`, Ops.td:1102/1114) — but those ops lower
to *calls* (`StringFromIntOpLowering`, EcoToLLVMHeap.cpp:1525/1542), so they
are "converted" without being inlined. Improving them is sub-dialect-section
work; they are cited here as proof that call-lowered ops are a legitimate
intermediate state: the op boundary already buys typed operands, `[Pure]`-able
semantics, and freedom to change the lowering without touching the compiler.

### Recommendations

Gates common to all: full E2E via `cmake --build build --target full`
(never `check` — conversions regenerate `.mlir`), plus the self-host
bootstrap fixed-point gate (stage output byte-equality at the fixed point;
the *first* build's `out.mlir` will legitimately differ since these change
codegen). Wall/RSS deltas measured with major-GC counts recorded (the
GC-trigger lottery, memory: lss-exploitation).

- **R1 — `List.cons` → `eco.construct.list` intrinsic.** Add the `"List"` arm
  to `kernelIntrinsic` (Intrinsics.elm:312-334, new `Intrinsic` ctor +
  `generateIntrinsicOp` arm), reusing KernelAbi.elm:310-317 head-kind
  selection; resolve the `EcoListTemplate` hint question (option 1 or 2 above,
  EcoListTemplate.cpp:147-149) in the same change. **Effort M** (the intrinsic
  is small; the trap analysis and gating are the work). **Expected effect:**
  removes the extern call + statepoint at 4,303 sites (25.5% of all kernel
  call forms) in favor of the already-shipped HEAP_034 bump path — the same
  *deleted-per-op-work* family as Run M's (a.k.a. C2's) −1.72% mean wall
  (rounds −1.74%/−1.69%) from 11,149 de-statepointed sites on identical allocation (benchmarks/tier2-opt.md:162-180);
  secondary: shrinks kernel GC-freeness poison (CGEN_072) and the borrow
  census's largest poison line (4,151 args). No number promised; measure.
  **Gates:** full E2E; `TEST_FILTER=codegen` then `TEST_FILTER=elm`;
  EcoListTemplate scratch-site count ≥ baseline; heap-validate suite
  (`ECO_HEAP_VALIDATE`); bootstrap fixed point.
- **R2 — Fold the backtrace into `eco_crash`, then emit `eco.crash` at crash
  sites.** Stage (a): port Crash.cpp:23-29's backtrace + message wording into
  `eco_crash` (RuntimeExports.cpp:2788-2807) — **Effort S**, pure C++,
  behavior-preserving prep. Stage (b): terminate regions with `eco.crash` at
  applied `Crash.crash` sites — **Effort M** (region surgery in Expr.elm or a
  pre-SCF rewrite). Fallback if (b) stalls: stamp the extern gc-leaf+noreturn
  (ATTRIBUTE-ONLY). **Expected effect:** 513 statepoints deleted, noreturn
  visible to LLVM, one poison source removed; crash paths are cold, so this is
  a code-size/attribute win, not a wall win. **Gates:** full E2E (crash-path
  tests), diff of crash output format in E2E goldens, bootstrap.
- **R3 — Json/encoder constructors → `eco.construct.custom`.** Intrinsic arms
  for the `makeDecoder*`-shaped symbols with ctor ids mirrored from
  JsonExports.cpp:57-79; land the ctor-id golden test (both Json `DEC_*` and
  Bytes `EncoderTag`) **first**. **Effort M** (mechanical × 30, plus the
  test). **Expected effect:** ~nil on the benchmark (28 sites here); real
  effect is user-program JSON and 30 fewer opaque symbols. **Gates:** full E2E
  with `TEST_FILTER=json`-ish suites (test/elm-json round-trip goldens),
  golden ctor-id test, bootstrap.
- **R4 — Close the `ArrayEmpty`/`ArraySingleton` emission gap.** Make the
  CAF-thunk body path consult intrinsics for nullary kernels, and widen the
  singleton pattern (Intrinsics.elm:661-668). **Effort S. Expected effect:**
  106 sites of surface hygiene, ~nil wall (CAF-memoized). **Gates:** full E2E,
  bootstrap.
- **R5 — Dynamic kernel census.** A per-symbol call counter behind an env flag
  (pattern: the existing `eco_g_cons_sites` tally, HeapHelpers.hpp:630-646)
  or perf sampling over Stage 7a, reported like the borrow census histogram.
  **Effort S. Expected effect:** converts this section's static ranks into
  heat evidence before any L-effort spend; the TIER pattern says this ordering
  is not optional. **Gates:** counter build must be flag-off-identical.
- **R6 — Decide the PAP policy before deleting anything.** Adopt the rule
  above (deletable ⇔ zero direct + zero PAP across the 990-file corpus), and
  size kernel-closure-lookthrough (design_docs/kernel-closure-lookthrough.md)
  against its only measured beneficiaries: `Bytes_read_*` (410) +
  `decodeFailure` (151) + `Crash_crash` (13). **Effort:** the decision is S;
  the pass is L and, on this evidence, not yet justified — record it as
  blocked-on-R5 heat data. **Gates:** n/a (policy).

---

## 5. New sub-dialects (Q4): what to model as ops, what to call through, what to leave opaque

**Headline verdict first:** no new *registered* MLIR dialect is proposed.
Every recommendation below extends the existing `eco` op namespace (plus BF
reification coverage); “sub-dialect” in this document means a coherent op
family within `eco`, the way `eco.int.*` / `eco.array.*` already are. The
one candidate for a genuinely separate dialect — a decoder/json dialect — is
considered and rejected in §Q4.4.

### Q4.0 The precedent, the cost model, and the three lowering strategies

**BF (ByteFusion) is the in-tree existence proof.** It is a dialect built for exactly
one purpose — deleting opaque `Elm_Kernel_Bytes_*` calls — and it is the only kernel
family that fuses. It has **26 ops** and one type (`!bf.cursor`)
(`runtime/src/codegen/BF/BFOps.td`, `grep -c 'def BF_.*Op : BF_Op'` = 26; the audit's
"27" over-counted by one). Its write/width ops declare explicit effects —
`MemoryEffects<[MemWrite]>` on `bf.alloc`/`bf.write.u8` (BFOps.td:94,146),
`MemoryEffects<[MemRead, MemWrite]>` on `bf.write.bytes` (BFOps.td:215),
`MemoryEffects<[MemRead]>` on the width ops (BFOps.td:249,264,279) — something the
Eco dialect's kernel-facing `eco.call` does not (`Ops.td:1129-1167`: interface
traits only, no effect traits). The eight scalar read ops (`BFOps.td:356-455`) currently declare **no** effects
— a gap to close when BF is next touched (`bf.read.bytes`/`bf.read.utf8`
already declare `MemoryEffects<[MemRead, MemWrite]>`, BFOps.td:477,493). Lowering lives in one pass,
`runtime/src/codegen/Passes/BFToLLVM.cpp` (1,169 lines), scheduled at
`EcoPipeline.cpp:99`.

**Adding an op is cheap; the semantics are the cost.** A new pure op is ~60–120
lines across three existing files: one `def` block in `Ops.td`, one
`OpConversionPattern` in the appropriate `EcoToLLVM*.cpp`, one `Intrinsic` arm in
`compiler/src/Compiler/Generate/MLIR/Intrinsics.elm` (`type Intrinsic` at :27-53,
dispatch at `kernelIntrinsic` :312-334). **No bytecode change is ever needed**: the
Elm-side writer is string-keyed — `MlirOp` carries `name : String`
(`compiler/src/Mlir/Mlir.elm:100-110`). Allocating ops additionally need a
`GCRootCarrier` impl (`EcoOps.cpp`) and entries in `EcoGCPrepare`'s
`isMayAllocOp` / `hasFixedAllocSize` / `getFixedAllocSizeForGrouping`
(`Passes/EcoGCPrepare.cpp:40-102`).

**Three lowering strategies, and what each one actually buys.** The pipeline has no
canonicalizer and no CSE (`EcoPipeline.cpp:82-90` — the canonicalizer was measured
out for ~0.5 s of compile time; no op in `Ops.td` has `hasFolder`), so `[Pure]`
traits buy *nothing at the MLIR level today*. The honest win mechanisms are:

| Strategy | What it is | What it buys |
|---|---|---|
| **INLINE-IR** | op expands to LLVM IR, no call | deletes the call, the statepoint, and the `EcoGCPrepare` costs below; exposes the IR to LLVM `-O3` |
| **GC-LEAF-CALL** | op lowers to a call declared `gcLeaf=true` via `EcoRuntime::getOrCreateFunc` (`Passes/EcoToLLVMRuntime.cpp:122-155`) | RS4GC emits no statepoint; the call stops poisoning `propagateGcFreeLeafAttrs` (`EcoBackend.cpp`, CGEN_072, `invariants.csv:636`) |
| **STATEPOINTED-CALL** | op lowers to a normal statepointed call into C++ | typed operands (no boxing/tag dispatch), a named op the compiler can attach metadata to, and — because the op is not `eco::CallOp` — it is no longer an allocation-grouping barrier (`isGroupBarrier`, `EcoGCPrepare.cpp:110-121`) and no longer gets full live-root sets appended as operands (`isCallSafepoint`, `:125-140`) |

Two invariant constraints bind every INLINE-IR design: generated code may only
touch heap internals through the **blessed patterns** — header-tag-test +
addrspace(1) GEP/load with Tag_Forward handling per HEAP_030, fresh-object stores
per HEAP_031, the HEAP_034 bump diamond (`invariants.csv` FORBID_OPT_002,
FORBID_HEAP_002, which enumerates the exemptions explicitly) — so **each new
inline op must be added to that blessed list as part of landing**. And HEAP_034
restricts inline allocation to compile-time-constant, 8-aligned sizes ≤ 4096 B
(`invariants.csv:572`). Every change below is additionally gated on the self-host
byte-identity bootstrap and the full E2E suite, like all codegen work.

Call-site counts below are static counts from the self-compiled compiler
(`kernel-callsites.txt`: 17,005 sites over 133 symbols; cross-checked against the
84 MB textual MLIR — e.g. `Utils_append` 3,465 listed vs 3,464 `eco.call` forms,
`Scheduler_andThen` 1,634 vs 1,633; the ±1 is the declaration/PAP reference).
Every one of these sites today is a bare
`"eco.call"(...) <{callee = @...}> : (!eco.value, ...) -> !eco.value` — the mono
type information is already erased by MLIR time, so **all type-splitting decisions
must happen at emission, in `Intrinsics.elm`/`Expr.elm`, where
`argTypes : List Mono.MonoType` is still in hand** (`Intrinsics.elm:308-334`).

---

### Q4.1 `eco.string.*` — the largest un-modelled surface

Today the dialect has exactly three string ops — `eco.string_literal` (`[Pure]`,
`Ops.td:1076`), `eco.string.from_int` (:1102), `eco.string.from_float` (:1114), the
latter two lowering to calls — while all **31** `Elm_Kernel_String_*` exports
(`elm-kernel-cpp/src/KernelExports.h:107-147`) are opaque; 25 of them appear in the
self-compile for **503 sites**, plus the string-typed share of `Utils_append`
(3,465 sites) and `Utils_equal`/`compare` (1,357/296), plus
`Bytes_getStringWidth` (697 sites — a string-width scan, not a bytes op).

**The central design constraint: strings have SIX heap representations** —
`Tag_String`, `Tag_StringRope`, `Tag_StringSlice`, `Tag_LargeStringHeader`,
`Tag_StringUtf8View`, `Tag_StringUtf8Leaf` (`runtime/src/allocator/Heap.hpp:80-112`)
plus the embedded `Const_Empty` constant word (Heap.hpp:186-190) — with a 6×6 tag
matrix inside every binary op (`design_docs/theory/string_rope_representation_theory.md`).
Open-coding that in MLIR is not viable, so **most string ops cannot be INLINE-IR**.
The honest menu is the three-way split:

**(a) INLINE-IR — the O(1) header ops.** HEAP_025 (`invariants.csv:563`) defines
`header.size` as the logical UTF-16 length **for every string form** (verified per
tag: `Heap.hpp:101` for LargeStringHeader, `:111-112` for the UTF-8 forms;
`StringOps::rawLen` is a single `u32` load, `StringOps.hpp:112`, and
`StringOps::length` = `rawLen` + null guard, `:239-242`). The `Header` layout is
`{u32 bits; u32 size}` (`Heap.hpp:163-175`), so string length is a **u32 load at
byte offset 4** — note this differs from arrays, whose length is a *separate* field
at offset 8 (`ElmArray`, `Heap.hpp:722-727`; `layout::ArrayLengthOffset = 8`,
`EcoToLLVMInternal.h:352`). The lowering is a line-for-line analogue of
`ArrayLengthOpLowering` (`EcoToLLVMHeap.cpp:1219-1250`): `ptr_ind` test for the
`Const_Empty` empty string (select 0 — mirroring the export's `isEmptyString`
guard, `StringExports.cpp:18-27`), else forward-checked resolve + GEP@4 + `load i32`
+ zext.

**(b) GC-LEAF-CALL — the non-allocating predicates.** Verified allocation-free end
to end (no `alloc::`/`eco_alloc` on any path; C++-heap `std::vector` only):
`StringOps::startsWith` (`StringOps.hpp:688-714`), `endsWith` (:719-748),
`contains` (:645-683) — three tiers each: UTF-8 memcmp / single-segment memcmp /
`charAt` loop — and `StringOps::equal` (:1486-1535) / `compare` (:1544-1614), whose
mixed-form arms use a width-aware segment lockstep explicitly documented as
"equal/compare never allocate in between" (:1455-1460). (HEAP_025's text still
says equal/compare "flatten"; the code no longer does — the invariant text is
stale, flag for update.) These stay C++ but their calls stop costing statepoints
and stop poisoning CGEN_072.

**(c) STATEPOINTED-CALL, but TYPED — the allocators.** `append`, `slice`, `cons`,
`uncons`, `join`, `split`, … genuinely allocate variable-size results with
config-dependent regime switches (`append` is memcpy-shaped below 32,768 units and
only builds a rope above, `StringOps.hpp:477-537`; `slice` copies at ≤ 128 units,
`StringOps.cpp:307-473`), so the call stays. The op's value is the **typed operand
signature, the removal of runtime tag dispatch, and the grouping/liveness relief**
— not inlining.

#### `eco.string.*` op specs

| Op | Operands → results | Traits | Lowering | Retires (sites) | Win mechanism | Risks |
|---|---|---|---|---|---|---|
| `eco.string.length` | `!eco.value → i64` | `Pure` | **INLINE-IR**: ptr_ind test → 0, else resolve + GEP@4 + `load i32` + zext | `String_length` (102) | call+statepoint deleted at the hottest string op; un-poisons callers | must join the FORBID_HEAP_002 blessed-pattern list; Tag_Forward handling per HEAP_030 |
| `eco.string.eq` | `(!eco.value, !eco.value) → i1` | `Pure` | **GC-LEAF-CALL** new export `eco_string_eq` → `StringOps::equal`; result decode = `trunc` (boxed Bool word bit 0 IS the i1, `Heap.hpp:180-183`) | string-typed share of `Utils_equal` (≤1,357) + the per-pattern call hardcoded by string-`case` lowering (`EcoControlFlowToSCF.cpp:748-833`) | skips `eqHelp`'s whole tag ladder; no statepoint | share of `Utils_equal` traffic that is string-typed is **unmeasured** — emission-side census first |
| `eco.string.cmp_order` | `(!eco.value, !eco.value) → !eco.value` | none (reads GC-mutable Order globals) | **GC-LEAF-CALL** `StringOps::compare` + `eco_get_order_*` getters (already gcLeaf, `EcoToLLVMRuntime.cpp` Order decls; same shape as `eco.int.cmp_order`, `EcoToLLVMArith.cpp:1008-1041`) | string share of `Utils_compare` (≤296) + `lt`/`gt`/`ge` (124) | Dict/Set-over-String-keys hot path | same census caveat |
| `eco.string.starts_with` / `ends_with` / `contains` | `(!eco.value, !eco.value) → i1` | `Pure` | **GC-LEAF-CALL** into `StringOps::{startsWith,endsWith,contains}` | 48 / 5 / 7 | statepoint + poison removal | low traffic; do as a batch with the same plumbing |
| `eco.string.code_unit_at` | `(!eco.value, i64) → i16` | `Pure` | **GC-LEAF-CALL** new export wrapping `StringOps::charAt` | nothing directly — **an enabler** | see below | out-of-range returns 0 (charAt semantics) — document, don't "fix" |
| `eco.string.utf8_width` | `!eco.value → i64` | `Pure` | **GC-LEAF-CALL** `Elm_Kernel_Bytes_getStringWidth` body (verified GC-allocation-free incl. its `std::u16string` snapshot arm, `BytesExports.cpp:310-366`) | `Bytes_getStringWidth` (697) | fifth-hottest poisoning symbol in the borrow census (696, behind List.cons/Utils.append/Scheduler.andThen/succeed, `design_docs/borrow-inf-census.md:864`) | none beyond R1's plumbing — this can also ship as attribute-only (R1) with no op |
| `eco.string.append` | `(!eco.value, !eco.value) → !eco.value` | `Pure` + `GCRootCarrier` | **STATEPOINTED-CALL** new export `eco_string_append` → `StringOps::append` | string half of `Utils_append` (part of 3,465) | see type-split below | none new — same callee the kernel dispatches to today |
| `eco.string.uncons` | `!eco.value → !eco.value` | `Pure` + `GCRootCarrier` | v2: INLINE-IR over `code_unit_at` + three constant-size inline allocs (slice/view 24 B + Tuple2 24 B + `Just` 24 B, all HEAP_034-eligible) | `String_uncons` (18) | O(1) char-by-char parsing loops | needs a variable-`size` header-word emission (`shl`+`or` on `composeHeader`); **defer** until (a)–(c) land |

**`code_unit_at` is the enabling primitive, with an honest caveat.**
`StringOps::charAt` (`StringOps.hpp:410-463`) already exists in exactly the right
shape — iterative (deep ropes cannot blow the C stack), tag-dispatched over all six
forms, **allocation-free so callers need no rooting** (:407-409) — and is
**unexported** (`grep charAt elm-kernel-cpp/src/KernelExports.h` = nothing). It
unlocks (i) Elm-source rewrites of the six `String` HOFs
(`map/filter/any/all/foldl/foldr`, 6 symbols / ~37 sites, each currently paying a
full `std::vector<u16>` snapshot + per-char dynamic closure apply,
`StringExports.cpp:225-233,251-354`), and (ii) the four scan-shaped `Parser`
kernels (`isAsciiCode`, `chompBase10`, `consumeBase`, `consumeBase16`,
`ParserExports.cpp:132,284-336`). The caveat: **the self-compiled compiler has zero
`Elm_Kernel_Parser_*` call sites** (`kernel-callsites.txt` — the compiler uses its
own hand-written parser), so the Parser payoff accrues only to elm/parser-using
programs; inside the self-compile the payoff is the HOF/`toInt`/`toUpper` rewrites.

**The `Utils_append` type-split — the single biggest typed-call win (3,465
sites).** `Elm_Kernel_Utils_append` re-derives at runtime what the compiler knew
statically: `Utils.cpp:822-846` does `isString(a) && isString(b)` → strings, else
`Tag_Cons`/`Tag_ConsChunk`/`isNil` → lists, else **silently returns `a`**
(:844-845 — a swallowed type error that disappears with the split). The emission
hook already exists and already sees the mono types: `utilsIntrinsic`
(`Intrinsics.elm:557-634`) matches on `( name, argTypes )` and today covers only
Int/Float/Char comparisons. Add
`( "append", [ MString, MString ] ) → eco.string.append` and
`( "append", [ MList _, _ ] ) → eco.list.append` (→ `ListOps::append`,
`ListOps.cpp:262`); genuinely polymorphic residue (an `MVar` argument) falls
through to the kernel call unchanged, so the kernel symbol stays as the fallback.
Borrow-census upside: `Utils.append` is the **#2 kernel poisoner** (3,270 heap
args, `borrow-inf-census.md:864`); typed ops with declared `KernelSigs`-style modes
recover those without growing the whitelist's audit debt.

---

### Q4.2 `eco.task.*` — Task construction as heap ops

**Scale.** `Scheduler_andThen` (1,634) + `succeed` (999) + `fail` (168) +
`onError` (113) = **2,914 sites = 17.1%** of all 17,005 kernel call sites in the
self-compiled compiler. Every one is pure Task-graph construction: the four exports
decode boxed args and call `taskSucceed`/`taskFail`/`taskAndThen`/`taskOnError`
(`SchedulerExports.cpp:16-46`), each of which is a single fixed-shape
`allocTask(ctor, value, callback, kill, task)` with unused fields set to the
`listNil()` constant (`Scheduler.cpp:123-157`). These four are the *named pure-
constructor exemptions* of KERNEL_TASK_IO_001 (`invariants.csv:590`), so modelling
them as construction ops is invariant-aligned by definition.

**The heap tag is `Tag_Task`, not `Tag_Custom` — verified, so `construct.custom`
cannot build it.** `Tag_Task` is its own tag (`Heap.hpp:90`) with its own struct
(`Heap.hpp:606-623`): `Header` + a packed `ctor:CTOR_BITS | id | padding` word +
`Unboxable value` + `HPointer callback, kill, task` — 48 bytes. `header.unboxed`
slot 0 says whether `value` is boxed (scanner/scheduler dispatch on it,
`Heap.hpp:601-605`). `allocTask` (`HeapHelpers.hpp:2016-2038`) is fully
data-independent: `id = 0` always, no counter, no branching — which is what makes a
compiler-emitted construction legal at all. The dialect currently has **no Task op
of any kind** (`grep -i task Ops.td` = 0 hits).

#### Op spec

| Op | Operands → results | Traits | Lowering | Retires (sites) | Win mechanism | Risks |
|---|---|---|---|---|---|---|
| `eco.construct.task` | `(value?: !eco.value \| i64 \| f64 \| i16, callback?: !eco.value, inner?: !eco.value) → !eco.value` + `I64Attr ctor`, value-kind derived from operand type | `Pure` + `GCRootCarrier` | **INLINE-IR**: HEAP_034 bump (48 B, constant, ≤4096 ✓) + `composeHeader(Tag_Task, kind, size)` + ctor word (`id=0`) + 4 stores (absent operands store the `Const_Empty` word, matching `listNil()`); plus `isMayAllocOp`/`hasFixedAllocSize`(48)/grouping entries in `EcoGCPrepare.cpp:40-102` | `Scheduler_{succeed,fail,andThen,onError}` — **2,914 sites** | statepoint + call deleted per Task node; `andThen` chains become groupable allocation runs instead of being split by call barriers (`isGroupBarrier`); borrow-census poisoners #3/#4 (`Scheduler.andThen`=1,625, `succeed`=907, `borrow-inf-census.md:864`) become precisely-moded ops | ctor indices pinned to `TaskCtor` (`HeapHelpers.hpp:1997-2004`) — add a golden test; scanner reads `header.unboxed` slot 0, so the kind bits must be exact |

Emission is a new `"Scheduler"` arm in `kernelIntrinsic` (none exists today,
`Intrinsics.elm:312-334`); the Scheduler kernels are not suffix-selecting
(`Monomorphize/KernelAbi.elm:145-192`), so all operands arrive boxed — the unboxed
`value` forms (`taskSucceedKind`, `Scheduler.cpp:128-137`) are runtime-internal and
can be ignored in v1.

**Design constraint carried from the invariant.** The KERNEL_TASK_IO_001 COROLLARY
(`invariants.csv:590`): *no code may write into a Task heap node after
construction* — the scheduler installs kill-handles by building a per-execution
`Task_Binding` **copy** (`Scheduler.cpp:884`), because Tasks may be aliased or
cached in memoized CAF slots. `eco.construct.task` is construction-only and the
lowering must never be "optimized" into reusing/patching an existing node; the
scheduler-side copy stays in C++ untouched.

**The eco-kernel builder half.** 47 of the 53 `Eco_Kernel_*` exports
(`eco-kernel-cpp/src/eco/KernelExports.h`; count re-verified: File 23 + Console 3 +
Env 2 + Process 3 + MVar 8 + Runtime 4 + NativeDriver 2 + Http 2) are the
`makeBinding` pattern — **zero IO at call time**, three fixed-shape allocations
(`runtime/src/platform/TaskBinding.hpp:143-163`): payload aggregate → 2-slot
closure over `bindingTrampoline<Body>` → `taskBinding` = `Task_Binding` node. The
remaining 6 split: log/crash/exit are KERNEL_TASK_IO_001's named exemptions,
while the 3 gc-roots registrars are void non-Task helpers outside the
invariant's scope (it governs only Task-returning symbols).
Making the compiler emit this shape needs exactly three pieces, two of which exist:

1. **Closure**: `eco.papCreate` (`Ops.td:1169-1221`) is an exact structural match
   (`FlatSymbolRefAttr $function`, variadic captures, `unboxed_bitmap`,
   `_result_kind`). **Blocker**: binding bodies are anonymous-namespace statics
   reached through `template <BindingBody Body>` trampolines
   (`TaskBinding.hpp:99-119`) — there is no stable symbol to name. Fix is
   mechanical: one `extern "C"` trampoline export per body
   (`Eco_KernelBody_File_readString`, …), 47 declarations.
2. **Task node**: `eco.construct.task` above (`ctor = Task_Binding`).
3. **Payload**: `eco.construct.tuple2/3/record` exist — and mostly *disappear*:
   capturing args directly in the closure (the `MVar_{read,take,put}` reference
   shape, `MVar.cpp:264-304`) deletes the payload object outright. Per the audit,
   **15 of the 47 builders carry a payload aggregate that direct capture
   eliminates** (report 06 §Part 2; spot-verified for the `File.cpp:602-664`
   `makeBinding<...>(payload)` family).

**Honest sizing.** The 47 eco-kernel builders are statically cold in the
self-compile (mostly 2 sites each; `MVar_put` 79, `MVar_read` 49, `Env_lookup`
36, `File_fileExists` 31 lead — ~310 sites total); their win is per-*construction* (3 objects → 2, minus one
cross-boundary statepointed call with `StackRootGuard` marshalling), not per-site.
The 2,914 Scheduler sites are the real static mass. Expected wall impact: the
closest measured prior is Run M — de-statepointing 11,149 sites bought −1.72%
mean wall (−1.74%/−1.69% rounds) / −2.06 MB text on identical allocation
(`benchmarks/tier2-opt.md:162-180`);
this family de-statepoints and inlines ~3K sites, so **sub-1% wall is the honest
expectation**, plus the borrow-oracle recovery which is unpriced. Task nodes are
short-lived scheduler food, so per the repeated series lesson (wall tracks
retention and deleted work, not allocation counts) do not promise an
allocation-count-driven win.

---

### Q4.3 Structural equality/compare — `eco.value.eq`

`Utils_equal` is the boxed structural root: **1,357 sites** (+ `notEqual` 63), plus
one call synthesized *by the lowering itself* for every string `case` pattern
(`EcoControlFlowToSCF.cpp:748-833`). The typed Int/Float/Char cases are already
intrinsics (`utilsIntrinsic`, `Intrinsics.elm:560-620`) — what reaches the kernel
is strings, lists, tuples, records, customs, and Dict-by-content.

**Verified facts the design rests on:**
- The export guard compares embedded constants **by word**: `equalRespectingConstants`
  (`UtilsExports.cpp:47-58`) — if either word has `ptr_ind` set, equality is
  `aBits == bBits`; a constant never equals a heap pointer. Golden words: False
  `0x4`, True `0x5`, Empty `0x6` (`Heap.hpp:212-218`); `ptr_ind` is bit 2
  (`PTR_IND_BIT`, `Heap.hpp:223`).
- `eqHelp` short-circuits on pointer equality first (`Utils.cpp:514-516`).
- **The whole equal/compare family is GC-allocation-free**: `eqHelp`'s families
  (`Utils.cpp:514-733`) allocate nothing; `dictEq` uses C++ `std::vector<Custom*>`
  (`Utils.cpp:746`); `cmp` returns the three pre-allocated rooted Order singletons
  (`Utils.cpp:33-49`); `StringOps::equal/compare` verified in Q4.1(b). The only
  `alloc::` calls in `Utils.cpp` are the one-time Order-singleton init (:35-39).

#### Op spec

| Op | Operands → results | Traits | Lowering | Retires (sites) | Win mechanism | Risks |
|---|---|---|---|---|---|---|
| `eco.value.eq` | `(!eco.value, !eco.value) → i1` | `Pure` | **INLINE fast path + GC-LEAF-CALL fallback**: (1) `a.word == b.word` → `true` (covers pointer-equal and identical constants — exactly `eqHelp:515` + the constant guard); (2) either word has bit 2 set → `false` (distinct constants, or constant vs pointer — exactly `equalRespectingConstants`); (3) else gc-leaf call `Elm_Kernel_Utils_equal`, decode via `trunc` (boxed-Bool word bit 0 = i1) | `Utils_equal` (1,357) + `notEqual` (63, add `xor`) | most dynamic hits are expected on arms (1)/(2) for Bool/constant-heavy code — **unmeasured**, needs the census; every remaining hit loses its statepoint | fallback gc-leaf legality requires the defect deletions below; do NOT stamp `memory(none)`/`speculatable` — motion-enabling attrs can move calls across statepoints (the hazard documented at `EcoToLLVMRuntime.cpp:885-891`), gc-leaf alone is the contract |
| *(deferred)* both-`Tag_Int` inline payload compare | — | — | needs an inline header load with Tag_Forward handling (HEAP_030) | — | payoff dubious: Int==Int is already `eco.int.eq` at typed sites; the boxed residue's composition is unmeasured | v2, census-gated |

**Preconditions (defects to delete first, both verified):**
1. **`Utils.cpp:550-556`** — `fprintf(stderr, "[eq] tag mismatch…")` behind a
   non-atomic `static int traceCount` on the tag-mismatch path. An observable side
   effect and a data race inside the function every equality in the program funnels
   through. It does not break *gc-leaf* (no GC), but it breaks the `Pure` trait
   claim, is UB under threads, and emits stray diagnostics from shipped binaries.
   Delete before the op lands.
2. **Document, decide, and test `eqHelp`'s `depth > 100 → return true`**
   (`Utils.cpp:560-563`): deep values silently compare equal while `cmp` has no
   limit, so `a == b` and `compare a b == EQ` can disagree. The op inherits
   whatever the kernel does — it must not silently *change* it, but landing an op
   on top of an unstated lie is how goldens rot.

`Utils_compare`/`lt`/`gt`/`ge` (296 + 80 + 41 + 3) get the same treatment with no
inline arm beyond `a.word == b.word → EQ`: **GC-LEAF-CALL only** (allocation-free
verified above; the Order singleton *getters* are already gcLeaf,
`EcoToLLVMRuntime.cpp` Order decls).

---

### Q4.4 Considered and rejected

**A JSON/decoder dialect — rejected.** The 30 decoder/encoder *constructors* are
each a single fixed-ctor `Tag_Custom` allocation (`JsonExports.cpp:464-539,1456`)
— i.e. already expressible as the existing `eco.construct.custom` (`Ops.td:873`);
that is an emission-side inlining task, not a dialect gap, and the self-compile
traffic is small (`Json_*` = 37 raw occurrences / 28 call forms, `kernel-callsites.txt`). The
*interpreters* — `runDecoder` (`JsonExports.cpp:552-1267`), `json::parse` +
`jsonToHeap`, `elmToJson` + nlohmann `dump()` — are hundreds of lines of C++ with
closure callbacks and a bit-exact double formatter; that is library code, not op
material. The real Json wins are C++-local (the quadratic `DEC_FIELD` re-transcode,
the dual-DOM pipeline — report 04 §9/10).

**A regex dialect — rejected.** Backed by vendored SRELL (`RegexExports.cpp:13`);
every interesting symbol is "run a regex engine" (Hard-Infeasible as ops), traffic
is 18 sites total, and the actual defects are runtime bugs (never-freed pattern
table + non-atomic id counter `RegexExports.cpp:36-46`, UTF-16 `Match.index` bug)
— none of which an op would touch.

**A time/http dialect — rejected.** Every Time/Http/File/Process symbol is either
a `KERNEL_TASK_IO_001` binding builder — fully covered by the `eco.task.*` family
(Q4.2), which is representation-level, not domain-level — or a fixed-ctor Custom
(`Platform_batch`/`leaf`, `Http_expect`, …) already expressible as
`construct.custom`. A domain dialect would duplicate `eco.task.*` per module for
zero additional coverage. The genuinely un-modellable parts (libcurl worker pool,
TimerService, scheduler run queue) are exactly the parts that must stay C++.

**BF extension instead of new read ops — fold-in, verified.** The `bf.read_*` ops
already lower the fused path; the C++ `Elm_Kernel_Bytes_read_*` symbols are the
**non-fused fallback**, and the fallback's dominant cost is not the load (1–2
instructions) but the **per-read `Tuple2` allocation** — `makeTuple2_ii/_if`
(`BytesExports.cpp:45-63`), one `eco_alloc_with_roots` + statepoint per primitive
read. The self-compile still has **~600 unfused read-path sites** (`read_u32` 411,
`decodeFailure` 152, `decode` 23, others 17 — `kernel-callsites.txt`): the
compiler's own bytecode reader is a decoder shape that `BytesFusion/Reify.elm`'s
hardcoded name-matching (`Reify.elm:229,390,489`) does not recognize. **Extending
BF reification coverage to those loops deletes the tuple-per-read entirely and is
worth more than any new `eco.*` read op** — and while there, give the eight
scalar `bf.read.*` ops the `MemoryEffects<[MemRead]>` traits they are currently
missing (`BFOps.td:356-455`; `read.bytes`/`read.utf8` already declare effects).

---

### Q4.5 Recommendations

Ordered by (call sites removed or de-statepointed) × (feasibility). Every item
carries the standard gates: full E2E suite, self-host byte-identity bootstrap, and
— for anything claiming a perf win — a before/after wall+RSS run recorded against
`benchmarks/`, per the tier pattern (×4+) that static censuses collapse without
dynamic evidence.

| # | Change | Effort | Sites affected | Gates / notes |
|---|---|---|---|---|
| **R1** | **Kernel gc-leaf allowlist** (attribute-only; the degenerate GC-LEAF-CALL with no new op): stamp `gc-leaf-function` on the verified non-allocating kernel decls — `Utils_{equal,notEqual,compare,lt,le,gt,ge}` (1,840), `Bytes_getStringWidth` (697), `String_{length,startsWith,endsWith,contains}` (162), `Bytes_width`/`decodeFailure` (167), `Char_toLower/toUpper` (4) — via the `is_kernel` lowering path (`EcoToLLVMFunc.cpp:26-95`) using the existing `gcLeaf` mechanism (`EcoToLLVMRuntime.cpp:143-149`). **Precondition: delete `Utils.cpp:550-556`.** | **S** | ~2,900 sites stop poisoning CGEN_072 | `ECO_GCFREE_LEAF=c` census before/after (coverage should rise from 5.27%); heap-validate; audit bar per `plans/gc-free-function-propagation.md:1267-1271` (§8 v2): *no transitive `alloc::` reach — string ops flatten…and allocate; comparisons may not* — re-verify each symbol at stamp time, gc-leaf only, never `memory(none)` |
| **R2** | **`Utils_append` type-split** → `eco.string.append` + `eco.list.append` (STATEPOINTED-CALL, typed), `utilsIntrinsic` arms; kernel symbol remains the polymorphic fallback | **M** | 3,465 | emission census of MString/MList/MVar split first (one-day `Intrinsics.elm` probe); deletes the `Utils.cpp:822-846` dispatch + silent fallback; KernelSigs rows for the two new callees |
| **R3** | **`eco.construct.task`** + `kernelIntrinsic "Scheduler"` arm (INLINE-IR, 48 B HEAP_034 bump) | **M** | 2,914 (17.1%) | golden test pinning `TaskCtor` order + Task field layout; KERNEL_TASK_IO_001 corollary review (construction-only, scheduler copy untouched); wall expectation sub-1% (Run M scaling), borrow-recovery unpriced |
| **R4** | **`eco.value.eq`** (+`ne`): inline word/constant fast path, gc-leaf fallback; same treatment call-only for `compare`/`lt`/`gt`/`ge` | **S** (after R1) | 1,840 | R1 is the precondition; behavior-identical to `equalRespectingConstants` by construction; document the `depth>100` asymmetry |
| **R5** | **`eco.string.length`** (INLINE-IR) + **`eco.string.code_unit_at`** + predicate ops (`eq`/`cmp_order`/`starts_with`/`ends_with`/`contains`, GC-LEAF-CALL) | **S–M** | 162 direct + enabler | add the inline length load to the FORBID_HEAP_002 blessed list; `code_unit_at` unlocks the Elm-source String-HOF track (separate section) and elm/parser programs (zero self-compile Parser sites — do not book compiler wall for it) |
| **R6** | **eco-kernel binding builders**: 47 `extern "C"` body trampolines + `eco.papCreate` + R3's op; direct captures delete 15 payload aggregates | **M** | ~310 static; per-construction dynamic | requires R3; `Process_wait`'s call-time `waitEnsureRegistered()` (`Process.cpp:266`) must move into its body first or the compiler-emitted shape has nowhere to run it |
| **R7** | **BF reification coverage** for the compiler's own bytecode-decoder loops; add `MemoryEffects<[MemRead]>` to `bf.read_*` | **M–L** | ~600 unfused read-path sites, tuple-per-read deleted | byte-identical decode goldens; this is compiler-side pattern work (`Reify.elm`), not runtime |
| **R8** | Do **not** build json/regex/time/http dialects (Q4.4); revisit only if a census shows the constructors hot | — | — | — |

The dependency spine is short: **R1 → R4**, **R3 → R6**; R2, R5, R7 are
independent. R1 is the only item with a measured mechanism already banked
(CGEN_072's −1.72% mean wall came from exactly this class of de-statepointing, with
kernels named as the excluded next lever, `plans/gc-free-function-propagation.md`
v2 notes); everything else must buy its keep at its census gate.

---

## 5b. The Elm-source track (the deferred target of §3–§5)

Several dispositions above say ELM-SOURCE. This is the section they defer to.
The candidates, with their static weights:

| Kernel(s) | Sites | Why C++ today | Why Elm source wins |
|---|---:|---|---|
| `List_reverse` | 468 | Tier-B chunk shunt (`config.list.chunks`, `Functions.elm:318`) | `reverse = foldl cons []` is exactly the cons-accumulator shape `EcoListTemplate` chunk-rewrites (`EcoListTemplate.cpp:90-180`), so Elm source plausibly keeps the chunk win *and* regains inliner/LSS/borrow visibility |
| `List_map2..map5` | 273 | hand-rolled GC-safe cursor driver | the 160-line C++ driver exists to re-root cursors across callback GCs (the historical stale-cursor bug, memory: eco-listmapn-stale-cursor-gc-bug); Elm source is GC-safe by construction and exposes `f` to LSS instead of `eco_apply_closure_eval` (`ListExports.cpp:481-571`) |
| `List_sortBy`/`sortWith` | 111 | `std::stable_sort` + index-sort idiom | comparator already calls back into Elm per comparison (HOF — zero boundary benefit); an Elm merge sort exposes the comparator to LSS; also retires the strict-weak-ordering UB (Appendix B6) |
| `JsArray_{foldl,foldr,map,indexedMap_Int,initialize_Int,initializeFromList_Int}` | ~676 | element loops over contiguous storage | HOF residue — every element crosses `eco_apply_closure_*`; needs `eco.array.get/set/length` (already inline, §4) as its primitives; `initialize*` additionally needs a mutable-fresh-array idiom (transient builder or `eco.array.set`-on-fresh, which the clone-based `ArraySetOpLowering` already optimizes when refcount-1 — verify at design time) |
| `String_{map,filter,any,all,foldl,foldr}` | ~40 | HOF over 6-representation strings | blocked on `eco.string.code_unit_at` (§4 R5); today each char crosses the closure boundary *and* the kernel snapshots the whole string (`StringExports.cpp:171-218`) — even `any`, which may exit at index 0 |
| `String_cons` | 68 | trivial wrapper | semantically `String.fromChar c ++ str` (audit-02); pure Elm once append is typed (§4 R2) |

**The shared mechanism.** Every candidate is a HOF (or trivially composed from
existing primitives). A HOF kernel is the worst case of the opaque boundary:
the kernel calls *back* into Elm through `eco_apply_closure_{typed,eval}`, so
neither side sees the other — no inlining in either direction, no LSS
devirtualization of the callback, full statepoint + root traffic per element.
Moving the loop to Elm source dissolves the boundary instead of decorating it:
the loop body and the callback co-optimize in MLIR, and every §4/§5 op
improvement compounds through it.

**Preconditions, honestly stated:**

1. **Fix the string divergences first** (Appendix B7): an Elm-source rewrite of
   String HOFs must not bake `reverse`-surrogate-corruption or the `toInt`/
   `toFloat` divergences into freshly-written Elm reference semantics.
2. **Chunk-win parity for `reverse`** must be demonstrated by the
   `EcoListTemplate` counters (scratch-site count ≥ baseline), same gate as §4
   R1.
3. **`concat`/`take` stay C++** for now: audit-03 found they are
   non-tail-recursive in their natural Elm form and genuinely lose the chunk
   representation; they are the counter-example that keeps this track a
   per-symbol decision, not a policy.
4. **Heat evidence before effort** (§3 R5): the static weights above are
   ranks, not wall forecasts; the dynamic census decides ordering.

**Recommendation R-ES1 (Effort M, per symbol S):** migrate in the order
`map2` → `reverse` → `sortBy`/`sortWith` → JsArray folds → String HOFs, each
gated on full E2E + bootstrap byte-identity + (for list ops) chunk-counter
parity + a wall check with majors recorded. Each migration deletes a
GC-rooting hazard class from C++ (audit-03 §6, audit-02 §bugs) as a side
effect.

---

## 6. Attribute modelling for kernels that stay C++ (Q5)

Parts 1–2 of this review established that most of the kernel surface either
becomes dialect ops or moves to Elm source. This section is about the
remainder — the kernels that stay C++ — and answers Q5: what facts about them
the compiler should carry, where those facts live, how they reach every
consumer, and how they are kept honest.

The current state is *four independent, mutually contradictory effect models*
(§ Consumers below) plus one real table (`Borrow/KernelSigs.elm`, 33 entries
of 130 kernel symbols actually referenced (§3) — 17,005 static kernel call sites in the
self-compiled compiler, of which the top 30 symbols cover 95.2%
(`kernel-callsites.txt`)). Every one of the audits (reports 01–06) found the
same shape: the facts exist only as C++ source, and each pass that needed
them either hand-transcribed a few (KernelSigs, the 1-entry devirt whitelist
at `compiler/src/Compiler/MonoSolver/Translate.elm:1854-1868`) or guessed —
in *both* unsound directions at once.

The empirical headline that makes a facts table worthwhile: the Part-1 audits
classified the 403 declared symbols (§2; audit-01…audit-06) and found that **almost none of them do anything at
call time**. Exactly 8 perform observable IO or terminate when called —
`Console_log`, `Crash_crash`, `Process_exit` (report 06:136, `Crash.cpp:30`,
`Process.cpp:227-234`), `Debug_log`, `Debug_todo` (report 05:61-62,
`DebugExports.cpp:26-54`), `Platform_sendToApp`, `Platform_sendToSelf`,
`Platform_worker` (report 05:43-45, `PlatformRuntime.cpp:549/574`) — plus one
*accidental* effect (`Utils_equal`'s stderr trace, `Utils.cpp:550-555`) and
~9 RT symbols that mutate runtime-internal state (Regex table
`RegexExports.cpp:36-46`, port registry, GC-root registration). Everything
else is a pure constructor, a pure reader, or a Task *builder* whose IO is
deferred into a `Task_Binding` body by `KERNEL_TASK_IO_001`
(`design_docs/invariants.csv:590`). The conservative defaults are therefore
wrong about ~97% of the surface — and the optimistic defaults (CafHoist) are
wrong about the other 3%.

---

### 6.A The attribute axes

Seven axes. For each: definition, consumers, and the *soundness direction* —
what breaks if the table over-claims (claims a stronger fact than the C++
delivers). Under-claiming is always safe: it reproduces today's behaviour.

### A1. `callTimeEffect : None | ObservableIO | RuntimeState | Noreturn`

What the kernel *does when called*, before returning. `None` covers Task
builders: per `KERNEL_TASK_IO_001` (`invariants.csv:590`) a Task-returning
kernel performs its IO when the scheduler steps the binding, not at
construction, and Tasks are immutable after construction — so building the
same Task twice vs. sharing one value is unobservable. `RuntimeState` is for
call-time mutation of runtime-internal structures (`Regex_never` /
`Regex_fromStringWith` register into a global table, `RegexExports.cpp:36-46,
204-205`). `Noreturn` is a distinguished effect: the call never returns
(`Crash_crash` `Crash.cpp:20-33`; `Process_exit` `Process.cpp:227-234`;
`Debug_todo` `DebugExports.cpp:44-54`, `[[noreturn]]` at `Debug.cpp:104`).

*Consumers:* `MonoInlineSimplify.isPureExpr` (DCE of dead lets,
`MonoInlineSimplify.elm:4780`; partial-forward guards `:3477,:3499`),
`CafHoist`/`CafDedupe` (evaluate-once merging), the planned Mono CSE
(`plans/cse-pure-calls.md:81-86` carve-out 3 demands exactly this
classification), unreachable-code pruning after `Noreturn` calls.

*Over-claim failure:* claiming `None` for an effectful kernel lets DCE drop,
CSE merge, or CafHoist reorder/deduplicate observable IO — silently wrong
output. Claiming returns-normally for a `Noreturn` kernel is comparatively
benign (missed optimization), but claiming `Noreturn` for a returning kernel
deletes live continuations.

### A2. `gcAlloc : None | Fixed shape | Unbounded` — plus a separate `cppAlloc` bit

Whether the kernel allocates **on the GC heap** on *any* path. This is the
axis gc-leaf denies: any GC-heap allocation may trigger a minor GC
(`HEAP_011`, `invariants.csv:392`) which moves nursery objects, so
`gcAlloc ≠ None ⇒ canTriggerGC ⇒ not gc-leaf`. `Fixed` (e.g. one 24-byte
Cons cell, one 5-slot Task node) vs `Unbounded` (input-sized spines, string
leaves) matters for the capacity-hoisting budget model (`CGEN_074`,
`invariants.csv:638`), not for gc-leaf itself.

The **C++-heap distinction must be first-class**: `malloc`/`std::vector`/
`std::u16string` inside a kernel never touch the nursery, cannot trigger a
collection, and cannot move Elm objects — so `cppAlloc = yes` is fully
compatible with gc-leaf. The audits found exactly this pattern repeatedly:
`Bytes_getStringWidth` is O(1) on UTF-8 forms but materialises a
`std::u16string` for non-UTF-8 slices/ropes (`BytesExports.cpp:309-366`, the
snapshot at `:336`) — C++ heap only, so it is gc-leaf-safe but *not*
"alloc-none" in the naive sense. Same for `Utils_equal`'s `dictEq` stacks
(`std::vector<Custom*>`, `Utils.cpp:746-796`) and `StringOps::equal/compare`
segment vectors (`StringOps.hpp:1520,1593`). An axis that cannot express
"gcAlloc=None ∧ cppAlloc=yes" would either block these rows or tempt someone
to lie; both are failure modes.

*Consumers:* gc-leaf stamping on the kernel declaration (the poison source in
`propagateGcFreeLeafAttrs`, `EcoBackend.cpp:1666` — "indirect call, or
non-gc-leaf declaration"), `EcoGCPrepare` root sets and allocation grouping
(§B), capacity-check hoisting budgets (`CGEN_074`), the borrow oracle's
fresh-result reasoning.

*Over-claim failure — the worst in this section:* stamping `gc-leaf-function`
on a declaration whose body can GC means RS4GC leaves the call
un-statepointed; a minor GC beneath it moves the nursery while the caller
holds unrelocated `addrspace(1)` values — use-after-move heap corruption.
And unlike generated functions, **no structural assert catches a lying
declaration**: CGEN_072(c)'s hard build failure (`invariants.csv:636`)
checks that *stamped defined functions* contain no statepoint post-RS4GC; a
declaration has no body to check. This is why §D's audit harness exists.

### A3. `callsBackIntoElm : Bool` (the HOF bit)

Whether the kernel can invoke an Elm closure *during the call*
(`eco_apply_closure_*` reach). This bit poisons every other axis: a HOF
kernel's effective facts are the join of its row with the facts of an
*unknown* closure, i.e. top. `JsArray_foldl` allocates whatever its callback
allocates, performs whatever IO its callback performs, and can GC because the
callback can. The only axes that survive the join are the borrow modes —
KernelSigs already models closure-mediated aliasing in `resultAliases`
(`KernelSigs.elm:17-22`: "`foldl (\x _ -> x)` returns an element").

*Consumers:* all of them. `gcLeafEligible = (gcAlloc == None) ∧ ¬callsBackIntoElm`;
`cseSafe ⇒ ¬callsBackIntoElm`; CafHoist must treat a HOF call as effectful
unless the closure argument is itself provably pure (do not attempt this in
v1 — mark HOF rows non-hoistable and move on).

*Over-claim failure:* claiming ¬HOF for a callback-invoking kernel makes
every downstream claim wrong at once (gc-leaf unsound, CSE unsound, effect
model unsound). This bit must be audited by grepping the C++ body for
`eco_apply_closure` reach, not by reading the Elm type.

### A4. `params : List ParamMode`, `resultAliases : List Int` (existing axis)

Retention/aliasing: `PBorrowed` = "reads only; never stores or
returns-by-identity", `POwned` = default (`KernelSigs.elm:35-43`). Already
built, 33 audited entries (`KernelSigs.elm:51-167`), already consumed by
`Borrow/Constrain.elm:883-908` (miss ⇒ `poisonArgs … RKernel`) and
`Borrow/LssFacts.elm:243-249` (miss ⇒ `Poison PUnresolved`). Measured miss
cost: `poisonedByKernel = 26,988` heap args
(`design_docs/borrow-inf-census.md:503`); the census's own audit puts the
*recoverable* slice at ~2–3K sites because ~78% of defaulted calls are
genuine owners (`borrow-inf-census.md:1066-1080`) — the honest expected
impact of growing this axis is modest and the census says so.

*Over-claim failure:* `PBorrowed` on a storing kernel, or a too-small
`resultAliases`, means premature free / missed escape under a future B4 RC —
the whitelist discipline at `KernelSigs.elm:14-16` exists precisely because
this direction is unsound.

### A5. `cseSafe : Bool` (referential transparency at the Mono level)

May the compiler merge two saturated calls with identical arguments, or
evaluate one call once and share the result? Requires: `callTimeEffect ==
None`, `¬callsBackIntoElm`, and determinism (result depends only on the
arguments' reachable immutable heap — reads of init-once runtime state like
the Order singletons qualify; reads of the mutable regex table do not).
Allocation does **not** disqualify: Elm has no reference identity and `==`
is structural, so sharing one Cons cell between two `x :: xs` occurrences is
unobservable — `List_cons` is cseSafe despite allocating. Note this is the
exact predicate `plans/cse-pure-calls.md:81-86` requires ("defaulting to
*impure* for anything unlisted") and the one CafHoist/CafDedupe currently
*fake* with `home == "Debug"` (`CafHoist.elm:392-393`).

Deleting an *unused* call needs strictly more: `cseSafe ∧ totality == Total`
(A6) — dropping a call that throws or diverges changes behaviour. Merging
two ⊥-producing occurrences is acceptable under `--optimize` but can change
the crash *message*, and the E2E suite asserts on crash text
(`plans/cse-pure-calls.md:77-80`) — the table lets CSE check this instead of
discovering it in a red suite.

*Over-claim failure:* merged/erased observable behaviour; for
nondeterministic kernels, results that differ between occurrences collapse
to one.

### A6. `totality : Total | Throws | Diverges` — the divergence ledger

Whether the C++ body returns normally on every input, and — critically —
whether it *agrees with its intrinsic*. The audits found real divergences
that any attribute model must record rather than paper over:

| symbol | C++ body | intrinsic lowering | anchor |
|---|---|---|---|
| `Basics_modBy` | **throws** `std::runtime_error` on modulus 0 | returns 0 | `Basics.cpp:92-103` vs `EcoToLLVMArith.cpp:83-131` |
| `Basics_idiv` | UB / SIGFPE on 0 (`a / b` bare) | guarded, returns 0 | `Basics.cpp:88-90` vs report 01 (`EcoToLLVMArith.cpp:57-81`) |
| `Basics_remainderBy` | UB on 0 | guarded, returns 0 | `Basics.cpp:105-107` |
| `Basics_tan` | `std::tan` | `sin(x)/cos(x)` | report 01, `Basics.cpp:40` vs `EcoToLLVMArith.cpp:324-337` |
| `List_sortBy/sortWith` | strict-weak-ordering UB on embedded-constant keys | n/a | report 03 finding 8, `ListExports.cpp:730-736` + `Utils.cpp:305-306` |
| `Utils_equal` | `depth > 100 ⇒ true` (deep values "equal"); `cmp` has no limit | n/a | `Utils.cpp:560-562` |

A PAP-captured `modBy 0` throws through statepointed frames (terminate);
an inlined one returns 0. The table records both behaviours per row so that
any change to symbol selection (`KernelAbi.elm`) or intrinsic coverage is
checked against the ledger instead of silently changing semantics.

*Consumers:* DCE (A5), `nounwind` stamping (§C — a `Throws` row can never
carry `nounwind`), the Part-2 migration itself (each "make it an intrinsic"
change must consult the ledger).

*Over-claim failure:* `Total` on a throwing kernel lets DCE delete a crash,
and `nounwind` on it is LLVM-level UB.

### A7. `noreturn : Bool` (subsumed by A1 = `Noreturn`, listed separately because its consumers differ)

`Crash_crash` (527 static sites), `Process_exit`, `Debug_todo`. Consumers:
Mono-level unreachable-code pruning after the call; LLVM `noreturn` on the
declaration (post-RS4GC only, per §C policy — although `noreturn` does not
move the call, house policy is one rule with no case-by-case exceptions
pre-RS4GC). Note `eco.crash` already lowers to `eco_crash` + `unreachable`
(`Ops.td:478`, report 06), so the intrinsic path has this fact; the C symbol
does not.

**Derived facts (never stored, always computed):**
`canTriggerGC = (gcAlloc ≠ None) ∨ callsBackIntoElm`;
`gcLeafEligible = ¬canTriggerGC`;
`droppable = cseSafe ∧ (totality == Total)`;
`hoistable = cseSafe` (evaluate-once is a *strengthening* of merge-two).
Storing only orthogonal axes and deriving the rest keeps rows auditable —
each stored field has exactly one C++ question behind it.

---

### 6.B Consumers and today’s defaults — the contradiction table

Every row verified against the source on 2026-08-09.

| consumer | anchor | today's assumption about a kernel call | direction |
|---|---|---|---|
| `MonoInlineSimplify.isPureExpr` | `MonoInlineSimplify.elm:5114-5116` (`MonoVarKernel → False`), `:5131-5133` (`MonoCall → False`) | ALL kernels impure — blocks DCE of dead lets (`:4780`) and partial-forwarding (`:3477,:3499`) | sound, maximally conservative |
| `MonoInlineSimplify.computeCost` | `MonoInlineSimplify.elm:1230-1231` | a kernel callee costs **1** — unbounded C++ work behind the symbol is free, so thin wrappers around expensive kernels always inline | neither: a *cost* model with no cost axis |
| `CafHoist` | `CafHoist.elm:392-393` (`hasDebug = home == "Debug"`), `:918-922` (any `MonoCall` is a candidate), consumer at `:347` | all non-`Debug` kernels PURE — hoists them into once-per-process CAFs | **unsound-optimistic** (default-off, `Config.elm:321`) |
| `CafDedupe` | `CafDedupe.elm:92-119` — merges `MonoDefine` specs by region-zeroed structural `==`, **no purity check at all** | any two CAFs with identical bodies merge into one evaluation | **unsound-optimistic** (default-off) |
| borrow `Constrain` | `Constrain.elm:883-908` — `KernelSigs.lookup` miss ⇒ `poisonArgs … RKernel` (`:893`) | unlisted ⇒ all-owned, escapes, consumed. 26,988 poisoned heap args (`borrow-inf-census.md:503`) | sound, conservative |
| borrow `LssFacts` | `LssFacts.elm:243-249` — miss ⇒ `Poison PUnresolved` | same | sound, conservative |
| `propagateGcFreeLeafAttrs` | `EcoBackend.cpp:1658-1667` — a call to any non-gc-leaf *declaration* is poison, propagated callee→caller to fixpoint (`:1676-1684`) | every kernel extern can GC; one call disqualifies the whole caller chain | sound, conservative — and the measured bottleneck (Run M: 5.27% coverage *given* this exclusion, `benchmarks/tier2-opt.md:162-180`) |
| `EcoGCPrepare` | `isCallSafepoint` `EcoGCPrepare.cpp:125-140` (every non-musttail `eco.call`), `isGroupBarrier` `:110-121` (every call-like op) | every kernel call needs full live-root operands AND splits allocation groups | sound, conservative |
| LLVM `-O2/-O3` | `EcoToLLVMFunc.cpp:83-87` — bare external declaration, zero attributes | may read/write all memory, throw, not return, allocate, GC | sound, conservative |

Two findings worth stating plainly:

1. **The compiler currently holds both `∀k. impure` and `∀k∉Debug. pure`
   simultaneously**, in passes that can run in the same pipeline
   (`isPureExpr` vs `CafHoist`/`CafDedupe`). They cannot both be right, and
   neither consults the one table that exists (`KernelSigs` measures a
   different axis — aliasing, not effects).

2. **The optimistic side is falsified by the code today.** `Utils_equal`
   writes to stderr behind a non-atomic `static int traceCount` on its
   tag-mismatch path (`Utils.cpp:550-555`). `CafHoist`+`CafDedupe`, if
   enabled, will happily hoist and merge expressions containing
   `Utils.equal` calls (`home == "Utils" ≠ "Debug"`), changing how many
   trace lines a program emits — an observable-behaviour change performed by
   a pass whose entire effect model is one string comparison. The facts
   table converts this from an accident nobody checked into a checked
   property: the row for `(Utils, equal)` carries
   `callTimeEffect = ObservableIO` *until the fprintf is deleted* (R2), and
   CafHoist consults the row.

---

### 6.C Propagation: one table, reflected twice

### C1. The single source of truth: extend `KernelSigs` into `KernelFacts`

`Borrow/KernelSigs.elm` is already keyed `(home, name)` exactly like
`KernelTypeEnv` (`KernelSigs.elm:4-9`), already carries per-row C++ evidence
anchors, and is already imported by precisely the passes that consume the
borrow axis (`Constrain.elm:26`, `LssFacts.elm:26`). Extend it in place and
re-export the old shape:

```elm
module Compiler.GlobalOpt.KernelFacts exposing
    ( KernelFacts, CallTimeEffect(..), GcAlloc(..), Totality(..)
    , ParamMode(..), lookup, borrowSig )

type CallTimeEffect
    = EffNone          -- nothing observable at call time (incl. Task builders,
                       --   per KERNEL_TASK_IO_001)
    | EffObservableIO  -- stdio / fs / net / calls the app
    | EffRuntimeState  -- mutates runtime-internal tables (regex, ports)
    | EffNoreturn      -- exit()/abort — never returns

type GcAlloc
    = GcNone           -- provably zero GC-heap allocation on EVERY path
    | GcFixed Int      -- ≤ N bytes of statically known shapes per call
    | GcUnbounded      -- input-dependent

type Totality
    = Total | Throws | MayDiverge

type ParamMode = PBorrowed | POwned          -- unchanged

type alias KernelFacts =
    { params : List ParamMode                -- existing axis (KernelSigs)
    , resultAliases : List Int               -- existing axis (KernelSigs)
    , callTimeEffect : CallTimeEffect
    , gcAlloc : GcAlloc
    , cppAlloc : Bool                        -- informational; gc-leaf-compatible
    , callsBackIntoElm : Bool                -- HOF bit; audited from C++, not types
    , cseSafe : Bool                         -- table-validated: implies EffNone
                                             --   ∧ not callsBackIntoElm
    , totality : Totality
    , divergence : Maybe String              -- A6 ledger note (e.g. "C++ throws on
                                             --   modBy 0; intrinsic returns 0")
    , evidence : String                      -- MANDATORY "File.cpp:line" anchor
    }
```

`lookup : (Name, Name) -> Maybe KernelFacts`; a `Nothing` means *every*
consumer keeps today's behaviour (its own default, not a shared one — see
the default policy at the end). A build-time validation pass over the table
asserts the cross-field implications (`cseSafe ⇒ EffNone ∧ ¬HOF`;
`EffNoreturn ⇒ totality ≠ Total`; `evidence ≠ ""`), so an inconsistent row
is a compile error of the compiler, not a latent miscompile.

`computeCost`'s flat 1 (`MonoInlineSimplify.elm:1230`) is deliberately *not*
given an axis in v1: a cost model needs measurement, not audit, and the
repeated tier lesson is that static censuses collapse at admissibility
gates. Leave a `-- TODO cost axis` note in the module doc.

### C2. Reflection point 1 — MLIR: attrs on the `is_kernel` declaration

`generateKernelDecl` already emits every kernel as a `func.func` stub with an
attrs dict (`Functions.elm:1954-2014`; the dict at `:1995-2008` currently
carries `sym_name` / `sym_visibility` / `is_kernel` / `function_type`). Add
the *derived, backend-relevant* facts as attributes — not the whole record:

```
( "eco.gc_leaf",  BoolAttr True )   -- iff gcAlloc == GcNone && not callsBackIntoElm
( "eco.noreturn", BoolAttr True )   -- iff callTimeEffect == EffNoreturn
( "eco.readonly", BoolAttr True )   -- iff cseSafe (post-RS4GC option, §C4)
```

Emitting only derived bits keeps the MLIR contract small and makes the Elm
table the *only* place a human edits facts.

### C3. Reflection point 2 — LLVM: `KernelFuncOpLowering`, and the pre-RS4GC wall

`KernelFuncOpLowering` (`EcoToLLVMFunc.cpp:26-96`) currently lowers the stub
to a bare external `LLVM::LLVMFuncOp` with no attributes (`:83-87`). The
change: read `eco.gc_leaf` off the func.func and attach `gc-leaf-function`
via the `passthrough` array — the exact mechanism `getOrCreateFunc` already
uses for the 92 runtime helpers (`EcoToLLVMRuntime.cpp:143-149`). Precedent
that this is the intended seam: the runtime already stamps gc-leaf on
`Eco_Runtime_getOrderLT/EQ/GT` (`EcoToLLVMRuntime.cpp:916-929`) and
`eco_int_pow` (`:904-908`), while `Elm_Kernel_Utils_equal` — declared ten
lines above them for string-case lowering — deliberately gets nothing
(`:910-913`).

**The soundness wall, spelled out: pre-RS4GC, `gc-leaf-function` is the ONLY
attribute a declaration touching GC values may carry.** The policy comment at
`EcoToLLVMRuntime.cpp:884-891` (on the slot-cast barrier decls) documents the
bisected miscompile class behind `REP_LLVM_002` (`invariants.csv:16`):
motion-enabling attributes (`memory(none)`/`speculatable`/`willreturn`) let a
pre-RS4GC pass move or fold a call across a statepoint boundary, recreating
exactly the raw-i64-across-statepoint crossings that the fold-proof barriers
exist to prevent. `gc-leaf-function` is safe pre-RS4GC because it is not a
motion attribute — it only tells RS4GC "do not statepoint calls to this."
The one existing declaration with the full motion set — `eco_bump_state`,
`memory(none) + nounwind + willreturn + speculatable + gc-leaf`
(`EcoBackend.cpp:1005-1020`) — is the exception that proves the rule: its
signature is `() -> ptr` addrspace(0); no GC-managed value flows through it,
so there is no statepoint-relative ordering to violate. Every kernel that
takes or returns `!eco.value` is on the wrong side of that line until RS4GC
has made relocations explicit.

### C4. Design option (OPEN, not settled): post-RS4GC attribute stamping

The question: once RS4GC has run, can we stamp `memory(read) + nounwind +
willreturn` on the *audited* gc-leaf kernel declarations so LLVM's
EarlyCSE/GVN/LICM can eliminate repeated `String_length`/`Utils_equal`-class
calls? Today they cannot (§B last row; report 08 §B.3: EarlyCSE/GVN only CSE
calls attributed readnone/readonly).

**Why it is plausibly sound.** Post-RS4GC, every GC pointer live across a
statepoint is an *explicit new SSA value* (`gc.relocate`). This changes the
motion question structurally:

- CSE keyed on SSA arguments cannot merge two calls separated by a
  statepoint — the second call's argument is the relocated SSA name, not the
  original, so the calls are not congruent. The dangerous merge is
  impossible by construction, not by analysis.
- LICM can hoist a `memory(read)` call out of a loop only if its argument
  dominates from the preheader — which, post-RS4GC, implies no relocation of
  that value on the back-edge. Again structural.
- This is the same argument CGEN_072(d) (`invariants.csv:636`) already
  accepts for post-RS4GC *inlining* of stamped bodies: "sound because a
  stamped body holds no statepoint, so the inlined region lies strictly
  between the caller's statepoints whose relocations are already explicit
  SSA."

**Why it is not settled.** Three residual hazards, each needing its own
verification:

1. **`speculatable` stays forbidden even post-RS4GC.** Speculation hoists a
   call above the branch that guards it. Kernel bodies dereference their
   `HPtr` arguments assuming a type precondition the guard established
   (e.g. `String_length` reads `Header+4` of whatever word it is given,
   `StringOps.hpp:239-243` / `StringExports.cpp:18-27`); speculated onto a
   non-string or embedded-constant word, that is a wild load. Only
   `memory(read)`, `nounwind`, `willreturn` are on the table, and `nounwind`
   only for `totality == Total` rows (never `modBy`, A6).
2. **`memory(read)` must actually be true.** `Utils_equal`'s
   `static int traceCount ++` and `fprintf` (`Utils.cpp:550-555`) are
   *writes*; until R2 deletes them, `(Utils, equal)` cannot carry
   `eco.readonly` regardless of its GC-purity. The table's validation makes
   this connection mechanical (`cseSafe = False` while
   `callTimeEffect = ObservableIO`).
3. **The stamping point must exist in every backend configuration.** Read
   from `EcoBackend.cpp:2560-2700`, there are *three* orderings, not one:
   - **serial** (default single-module): gcfree (`:2565-2568`) → RS4GC
     (`:2603-2606`) → whole-module O2/O3 (`:2621-2627`). Stamping between
     RS4GC and opt works and is where the win would appear.
   - **`deferRS4GC`** (`job.rs4gcAfterOpt`, `:2582-2584`): opt runs *first*
     on statepoint-free IR, RS4GC after (`:2629-2630`). There is **no
     post-RS4GC opt window at all** — stamping is harmless but buys nothing,
     and stamping *before* opt in this config would be exactly the
     pre-RS4GC violation. Must be audited explicitly.
   - **`rs4gcInWorkers`** (parallel-opt, `:2595-2601`): the cheap-IPO
     prologue (IPSCCP/GlobalOpt/GlobalDCE, `:229`, `:2619-2620`) runs
     **pre-RS4GC** on the whole module; RS4GC then runs *inside each
     partition worker* before its per-partition O2/O3 (`:2586-2592`,
     single-partition variant `:2693-2694`). Stamping must therefore happen
     per-partition, after the worker's RS4GC — never on the pre-split module
     where the prologue would see motion attrs on statepoint-free IR.

   The clean implementation: stamp at the **end of
   `runRS4GCAndMaybeFramePointers`** (`EcoBackend.cpp:722`). That function is
   the single choke point every flavour already calls at exactly the
   post-statepointing moment (serial `:2605`, deferred `:2630`, both split
   workers `:383,:614`, single-partition inline `:2694`), and it already
   hosts CGEN_072(c)'s structural assert — the natural home for a sibling
   assert ("no motion attr on a kernel decl in a module that still has an
   un-statepointed GC function").

**Verification plan (gates before default-on):** (i) census mode first —
count kernel calls LLVM actually CSEs/hoists per partition (IR-diff of the
A/B partition dumps; the `ECO_GCFREE_LEAF=c` pattern, `EcoBackend.cpp:105-119`);
(ii) full heap-validate suite (the 1623-test walker suite) under both
`ECO_KERNEL_ATTRS={0,1}`; (iii) E2E `--target full`; (iv) bootstrap
self-host fixed point with *identical `out.mlir`* (the Run M shape:
`benchmarks/tier2-opt.md:169-172` — alloc/minors/majors/output identical,
only codegen differs); (v) A/B wall with major-GC counts recorded (the
GC-trigger-lottery discipline). Config audit: one run each with
`deferRS4GC` and `rs4gcInWorkers` forced, plus the default. Until all five
gates pass this stays an env-gated experiment.

---

### 6.D Enforcement: the table will rot unless it bites back

### D1. The invariant (proposed CSV row, `invariants.csv` format)

```
KERNEL_FACTS_001;CrossPhase;KernelFacts;proposed;Compiler.GlobalOpt.KernelFacts (the (home,name)-keyed extension of Borrow/KernelSigs.elm) is the ONLY source of per-kernel semantic facts (call-time effect, GC-allocation class, HOF bit, borrow modes, CSE safety, totality) - no pass may hard-code a kernel effect judgement by name or module string (the CafHoist home=="Debug" test and isPureExpr's blanket False become reads of this table). Every row carries a mandatory C++ evidence anchor (export-body file:line) and may only STRENGTHEN a fact (EffNone / GcNone / not-HOF / PBorrowed / cseSafe / Total) after an audit establishing no transitive reach to alloc::* / eco_alloc_* / eco_apply_closure* / IO from the export body; unknown or unlisted kernels keep each consumer's pre-table behaviour (isPureExpr False, borrow all-owned poison, no gc-leaf attr, EcoGCPrepare safepoint+barrier, CafHoist home-string test). Backend reflection: gcAlloc==GcNone && !callsBackIntoElm rows MAY carry gc-leaf-function on the kernel declaration (emitted via the func.func eco.gc_leaf attr, reflected in KernelFuncOpLowering); motion-enabling LLVM attrs (memory(*)/speculatable/willreturn/nounwind) on declarations whose signature carries !eco.value are FORBIDDEN until RS4GC has statepointed the containing module (REP_LLVM_002 miscompile class) - any post-RS4GC stamping lives inside runRS4GCAndMaybeFramePointers so all four RS4GC flavours (serial / deferred-after-opt / split workers / single-partition inline) preserve the ordering. Table changes require the dev-build KernelFacts audit harness (per-row GCStats allocation-delta assert) green over the E2E corpus;KernelFacts.elm|Passes/EcoToLLVMFunc.cpp|EcoBackend.cpp|CGEN_072|REP_LLVM_002|KERNEL_TASK_IO_001
```

### D2. Dev-build audit harness (feasible today against `GCStats`)

The claim that rots worst is `gcAlloc = GcNone` (A2's failure mode is heap
corruption with no assert to catch it). The counters to check it against
already exist: `GCStats` tracks `objects_allocated`/`bytes_allocated`
(`GCStats.hpp:53-54`) and, better, the per-tag ThreadLocalHeap census
`tlh_alloc_count_by_tag` (`GCStats.hpp:195-211`), recorded on **every
successful mutator allocation** at `ThreadLocalHeap.cpp:134`
(`GC_STATS_TLH_RECORD_ALLOC`). Stats compile in for every non-Release build
(`CMakeLists.txt:107-116`) and compile to zero-overhead no-ops otherwise
(`GCStats.hpp:786-791`).

Sketch (dev builds only, `ENABLE_GC_STATS=1`):

```cpp
// elm-kernel-cpp/test/kernel_facts_audit.cpp — table-driven.
// One row per GcNone claim, mirroring KernelFacts.elm (generated or
// hand-synced; the invariant makes drift a review item).
struct NoAllocClaim { const char* name; HPtr (*call)(); };
for (auto& c : claims) {
    uint64_t before = currentThreadStats().objects_allocated;   // nursery
    uint64_t beforeOld = oldGenStats().objects_allocated;       // + oldgen:
    c.call();                       // representative + adversarial inputs:
                                    // rope/slice/utf8 strings, chunked lists,
                                    // embedded constants, deep dicts
    assert(currentThreadStats().objects_allocated == before &&
           oldGenStats().objects_allocated == beforeOld &&
           "GcNone kernel allocated on the GC heap");
}
```

Three cautions from the measured record: (a) assert on *allocation count*,
not GC count — a test run that happens not to trip a collection proves
nothing about gc-leaf safety, but a zero-allocation delta does; (b) nursery
and old-gen keep **separate GCStats objects** (the capacity-hoisting
post-mortem trap) — check both; (c) `ECO_INLINE_ALLOC` inline-bump sites
bypass the counters (HEAP_034 census caveat, `invariants.csv:572`) but that
is irrelevant here: kernel-internal allocations are C++ calls through
`ThreadLocalHeap::allocate`, which is exactly what
`GC_STATS_TLH_RECORD_ALLOC` counts. Coverage is by construction
input-dependent — the harness proves presence of allocation, never absence —
so it is the *second* line of defence behind the human audit, catching rot
(someone adds an alloc to `StringOps::compare`) rather than proving theorems.
Adversarial inputs matter: `Bytes_getStringWidth`'s GC-allocation-freedom
holds on all four string forms only because the slice/rope path materialises
into a `std::u16string`, not the heap (`BytesExports.cpp:328-339`) — the
harness must include exactly those forms.

### D3. Review discipline: the borrow-census evidence-anchor style

The KernelSigs seed audit set the standard this table must keep:
`design_docs/borrow-inf-census.md:241-262` (§3a) records, per row, the
verdict *and* the verified C++ chain (e.g. "`Utils.cpp:400 compare→cmp`
(read-only), returns an `ORDER_*` singleton — ⚠ pre-allocated & GC-rooted,
aliases a global, never a param"), including the rows it *rejected*
(`Console.write` POwned, `KernelSigs.elm:24-27`) and why. Every KernelFacts
row follows the same form: claim, C++ anchor, the adversarial case
considered, and rejected-row rationale kept in the module comment so the
next auditor does not re-litigate it. The `evidence` field being mandatory
(and validated non-empty) makes "row without an audit" a compile error.

---

### 6.E Seed classification — top-30 census symbols + the predicate families

Verdicts below re-verified against the C++ on 2026-08-09 (not taken from
reports 01–04 on trust; divergences from them: none found on these rows).
`sites` = static call sites in the self-compiled compiler
(`kernel-callsites.txt`; these 30 symbols alone = 95.2% of all 17,005, and
the listed predicate families add 71 sites more). Legend: eff = callTimeEffect, alloc = gcAlloc (`cpp` marks
cppAlloc), HOF = callsBackIntoElm, cse = cseSafe, tot = totality,
**leaf** = gcLeafEligible (the stampable set). KS = row already in
`KernelSigs.elm:51-167`.

| # | symbol (sites) | eff | alloc | HOF | cse | tot | leaf | KS | evidence |
|---|---|---|---|---|---|---|---|---|---|
| 1 | `List_cons` (4158) | None | Fixed(1 Cons) | no | yes | Total | no | – | `ListExports.cpp:276` → `alloc::cons` (`HeapHelpers.hpp:630`) |
| 2 | `Utils_append` (3465) | None | Unbounded, cpp | no | yes | Total | no | – | `Utils.cpp:822-846`; string path `StringOps.hpp:477-537`, list path `ListOps.cpp:274` |
| 3 | `Scheduler_andThen` (1634) | None (Task ctor, KERNEL_TASK_IO_001) | Fixed(1 Task node) | no (stores closure) | yes | Total | no | – | `SchedulerExports.cpp:30` → `Scheduler.cpp:149-152` |
| 4 | `Utils_equal` (1357) | **ObservableIO** until R2, then None | **GcNone**, cpp | no | no→yes after R2 | Total (depth cap `:560-562`) | **yes** | KS | `Utils.cpp:463-733`; effect `:550-555`; `StringOps.hpp:1486-1533` alloc-free; `dictEq :746-796` C++ vectors; ListCursor is non-allocating (`HeapHelpers.hpp:812-821`) |
| 5 | `Scheduler_succeed` (999) | None | Fixed | no | yes | Total | no | – | `SchedulerExports.cpp:16` → `Scheduler.cpp:123-126` |
| 6 | `Bytes_getStringWidth` (697) | None | **GcNone**, cpp (`u16string` on slice/rope) | no | yes | Total | **yes** | KS | `BytesExports.cpp:309-366`; C++-heap snapshot at `:336` |
| 7 | `Crash_crash` (527) | **Noreturn** (stderr + exit 1) | GcNone, cpp | no | no | ⊥ | moot | KS | `Crash.cpp:20-33` |
| 8 | `List_reverse` (469) | None | Unbounded | no | yes | Total | no | – | `ListOps.cpp:530` |
| 9 | `Bytes_read_u32` (411) | None | Fixed(1 Tuple2) | no | yes | Total | no | – | `BytesExports.cpp:539` |
| 10 | `JsArray_foldl` (365) | join(closure) | join | **yes** | no | join | no | KS | `JsArrayExports.cpp:651` → `foldImpl:576` |
| 11 | `Utils_compare` (296) | None | **GcNone**, cpp | no | yes | Total (NDEBUG-UB note `Utils.cpp:214-217`) | **yes** | KS | `Utils.cpp:302-461`; returns rooted `ORDER_*` singletons (`:35-49`); `StringOps.hpp:1544-1608` alloc-free |
| 12 | `List_map2` (252) | join(closure) | join | **yes** | no | join | no | KS | `ListExports.cpp:592` → `kernelListMapN:432` |
| 13 | `Scheduler_fail` (168) | None | Fixed | no | yes | Total | no | – | `SchedulerExports.cpp:23` → `Scheduler.cpp:139-142` |
| 14 | `Bytes_decodeFailure` (152) | None | **GcNone** (embedded constant) | no | yes | Total | **yes** | – | `BytesExports.cpp:468-470`; `alloc::nothing()` = `HeapHelpers.hpp:196` |
| 15 | `JsArray_initializeFromList_Int` (118) | None | Unbounded | no | yes | Total | no | – | `JsArrayExports.cpp:982` |
| 16 | `Scheduler_onError` (113) | None | Fixed | no | yes | Total | no | – | `SchedulerExports.cpp:39` → `Scheduler.cpp:154-157` |
| 17 | `String_length` (102) | None | **GcNone** | no | yes | Total | **yes** | KS | `StringExports.cpp:18-27` → `StringOps.hpp:239-243` (one u32 load, all six tags) |
| 18 | `JsArray_initialize_Int` (97) | join(closure) | join | **yes** | no | join | no | – | `JsArrayExports.cpp:948` |
| 19 | `List_cons_Int` (92) | None | Fixed | no | yes | Total | no | – | unboxed-head variant of #1 |
| 20 | `List_sortBy` (89) | join(closure) | join | **yes** | no | **Throws** (SWO UB, report 03 #8) | no | KS | `ListExports.cpp:604+`; UB pair `:730-736` + `Utils.cpp:305-306` |
| 21 | `Utils_lt` (80) | None (via `cmp`) | **GcNone**, cpp | no | yes | Total | **yes** | KS | `Utils.cpp:802-804` |
| 22 | `MVar_put` (79) | None (always-binding) | Fixed(binding) | no | yes (Task value) | Total | no | – | KERNEL_TASK_IO_001 (`invariants.csv:590`); `MVar.cpp:264-304` |
| 23 | `String_slice` (73) | None | Unbounded (tiny-copy ≤128 units; rope recursion) | no | yes | Total | no | KS | `StringOps.cpp:307-473` |
| 24 | `String_cons` (69) | None | Unbounded (len+1 leaf) | no | yes | Total | no | – | `StringOps.hpp:1241-1270` |
| 25 | `JsArray_empty` (68) | None | Fixed (`allocArray(0)`) | no | yes | Total | no | – | `JsArrayExports.cpp:192` |
| 26 | `Utils_notEqual` (63) | inherits #4 (calls `equal`) | **GcNone**, cpp | no | as #4 | Total | **yes** | KS | `Utils.cpp:798-800` |
| 27 | `List_cons_Char` (56) | None | Fixed | no | yes | Total | no | – | as #19 |
| 28 | `JsArray_foldr` (49) | join(closure) | join | **yes** | no | join | no | KS | `JsArrayExports.cpp:655` |
| 29 | `MVar_read` (49) | None (always-binding) | Fixed | no | yes | Total | no | – | as #22 |
| 30 | `String_startsWith` (48) | None | **GcNone** | no | yes | Total | **yes** | KS | `StringOps.hpp:688-714` (memcmp tiers, no alloc) |

Predicate families completing the requested set (all re-verified
GC-allocation-free — the only allocations in `Utils.cpp` are the init-time
Order singletons at `:35-39`):

| family | leaf | evidence |
|---|---|---|
| `Utils_le` (0 sites in-corpus) / `gt` (41) / `ge` (3) | **yes** | `Utils.cpp:806-816`, thin wrappers over `cmp` |
| `String_endsWith` (5) / `contains` (7) | **yes** | `StringOps.hpp:719-748` / `:645-683`; `charAt` walk is allocation-free (`StringOps.hpp:410-463`, report 02 #1) |
| `Bytes_width` (15) | **yes** | `BytesExports.cpp:299` (report 04) — raw scalar read |

The stampable set from this table alone: `Utils_{equal,notEqual,compare,lt,
le,gt,ge}`, `String_{length,startsWith,endsWith,contains}`,
`Bytes_{getStringWidth,width,decodeFailure}` — 14 declarations covering
**1,357+63+296+80+41+3+102+48+5+7+697+15+152 ≈ 2,866 static call sites**
(16.9% of all kernel sites), every one of which today poisons its calling
function and its transitive callers in `propagateGcFreeLeafAttrs` and forces
a full statepoint + root spill around what is at most a header load and a
memcmp.

---

### 6.F Recommendations

Shared hard precondition for every stamping row below (R3, R5, R6): amend
CGEN_072's “ALL kernel externs” wording (invariants.csv:636) in the same
change — as written, the invariant forbids exactly this stamping (§8 H1).

Default policy, stated once and binding on all of them: **an unlisted kernel
behaves exactly as it does today, per consumer.** `isPureExpr` stays `False`
(do not widen unsoundly); borrow stays all-owned-poison; no gc-leaf attr is
emitted; `EcoGCPrepare` keeps safepoint + barrier; and `CafHoist`/`CafDedupe`
keep their current optimistic `home == "Debug"` behaviour for unlisted names
(do not regress a default-off pass by narrowing it — the fix for its
unsoundness is *listing* the effectful rows, which are few: §A's 8+1, most
already excluded as `Debug`/`Crash` or absent from CAF-closed subtrees). The
table only ever moves a listed row away from its consumer's default, in the
audited direction.

| # | recommendation | effort | gates | grounding |
|---|---|---|---|---|
| **R1** | Extend `KernelSigs.elm` → `KernelFacts` (record of §C1, re-export `borrowSig` for Constrain/LssFacts untouched); populate the §E seed rows with evidence anchors; add the table-consistency validation | **S** | `elm-tests`; row-by-row review in D3 style | table shape verified against both existing consumers (`Constrain.elm:883-908`, `LssFacts.elm:243-249`) |
| **R2** | Delete the `Utils_equal` stderr trace (`Utils.cpp:550-555`) | **S** | E2E `--target full` | removes the only live counter-example to "non-Debug kernels are call-time-effect-free"; unblocks `cseSafe`/`memory(read)` for the two hottest comparison symbols (1,357 + 63 sites) |
| **R3** | Reflect `gcLeafEligible` rows as `gc-leaf-function` on kernel declarations (`Functions.elm:1995-2008` attr → `EcoToLLVMFunc.cpp:83-87` passthrough), env-gated `ECO_KERNEL_GCLEAF` with census mode first | **M** | gcfree census delta (`[gcfree]` line, `EcoBackend.cpp:1720-1725`) under `=c`; full heap-validate; E2E; bootstrap self-host fixed point; A/B wall with majors recorded | mechanism prior: Run M de-statepointed 11,149 sites at 5.27% function coverage for −1.72% mean wall (rounds −1.74%/−1.69%) / −2.06 MB text on identical alloc/output (`benchmarks/tier2-opt.md:162-180`). The 14 seed decls cover ~2,866 poisoning sites (§E); the *function-coverage* uplift is unknown until the census runs — do not project a wall number. Named as unbuilt v2 in `plans/gc-free-function-propagation.md:1268-1271` with the same audit bar ("no transitive `alloc::` reach") |
| **R4** | Wire the four Elm-side consumers to `lookup` with status-quo defaults: `isPureExpr` kernel/call arms may return `True` only for listed `droppable` rows; `CafHoist`/`CafDedupe` refuse listed rows with `callTimeEffect ≠ None`; CSE plan's carve-out 3 reads `cseSafe` | **M** | E2E; `TEST_FILTER=elm`; for CafHoist a flag-on A/B (it is default-off, `Config.elm:321`) | contradiction table §B; `plans/cse-pure-calls.md:81-86` |
| **R5** | `EcoGCPrepare`: listed `gcLeafEligible` kernel callees stop being call-safepoints and group barriers (`EcoGCPrepare.cpp:110-140`) — shrinks root operand lists and merges allocation groups split by e.g. `String_length` | **M** | flag-gated; MLIR-level: `ECO_LOWERING_VALIDATION` liveness audit (`EcoPipeline.cpp:94-96`); heap-validate; E2E | mechanism: report 08 §B.2(a,b) — roots appended as call operands and D3-conservative barriers. Compile-time bonus: fewer roots = less liveness work in the pass M4 already had to economise (`EcoPipeline.cpp:82-90`) |
| **R6** | **OPEN design option** — post-RS4GC stamping of `memory(read)+nounwind+willreturn` on listed rows, implemented at the end of `runRS4GCAndMaybeFramePointers` (`EcoBackend.cpp:722`) so all four RS4GC flavours keep ordering; `speculatable` remains forbidden; explicit audits of the `deferRS4GC` (`:2582-2584`, no post-RS4GC opt window) and `rs4gcInWorkers` (`:2595-2601`, pre-RS4GC cheap-IPO) configurations | **L** | the five-gate plan of §C4; lands only after R3 has been default-on through a full bootstrap cycle | soundness argument parallels CGEN_072(d); no measured prior exists for the CSE harvest — census before A/B, per the ×4 tier lesson that static counts collapse at admissibility gates |
| **R7** | Land `KERNEL_FACTS_001` (D1) + the dev-build GCStats audit harness (D2) **in the same change as R3** — the stamp and its enforcement are one unit | **S** | harness green over E2E corpus in a `dev`-preset build; invariant row reviewed | counters verified present and per-thread (`GCStats.hpp:53-54,195-211`, `ThreadLocalHeap.cpp:134`, `CMakeLists.txt:107-116`) |
| **R8** | Record the A6 divergence ledger rows (`modBy`/`idiv`/`remainderBy`/`tan`/`sortBy`-SWO/`equal`-depth) in the table now, before any Part-2 migration touches those symbols | **S** | review only | each divergence verified: `Basics.cpp:88-107` vs `EcoToLLVMArith.cpp:83-131`; `ListExports.cpp:730-736`; `Utils.cpp:560-562` |

Ordering: R1+R2+R8 (the table exists, is honest, and is cheap) → R3+R7 (the
first backend consumer, with its enforcement) → R4/R5 in either order →
R6 only after R3 has survived a bootstrap cycle. Wall-impact expectations
should stay anchored to the one repeated lesson in the measured record: wall
tracks retention and deleted work, not counts — R3/R5/R6 are *deleted-work*
changes of exactly the Run M kind (statepoints, root spills, redundant
calls), which is why they are worth pursuing even though no allocation
number moves; and that same record (K5's +18.3% revert, chunked-list v1's
+7.6%) is why every one of them carries a census gate before a default flip.

---

## 7. Wholesale re-implementation candidates (Q6)

### Scope and method

This section answers Q6: which kernel families are worth **replacing outright** — new
data structure, compiler taught the new shape — rather than shaving at the boundary
with intrinsics or attributes. "Wholesale" is held to the standard set by the two
precedents that already shipped in this tree, and every verdict is scored against the
mechanism rule this codebase has now measured four separate times: **wall tracks
retention and deleted work, not allocation counts** (LH1, benchmarks/tier2-opt.md:258-275;
K4/K6, plans/mono-comparable-key-optimization.md via benchmarks/tier2-opt.md:307,325;
chunked lists, plans/chunked-list-representation.md:386). A candidate with no
retention story and no executed-work-deletion story is rejected here no matter how
many call sites it has.

### The two precedents, and the transferable lessons

| Precedent | What was replaced | Compiler taught | Result | Anchors |
|---|---|---|---|---|
| elm/bytes → BF dialect | The `Encoder` **interpretation**: tree declared in Elm (`Bytes/Encode.elm:46-57`), C++ walker (`writeEncoder`, `BytesExports.cpp:93-105`) kept only as the non-fused fallback | Whole-combinator recognition → reification → `bf.*` ops with declared effects, cursor SSA-threaded (BFOPS_001/002, invariants.csv:430-432), single output buffer, no intermediates (BFOPS_007/011, invariants.csv:442,450) | The only kernel family that fuses; the per-read `Tuple2` + `Maybe` allocations vanish on the fused path | design_docs/fused-bytes-compilation.md; runtime/src/codegen/BF/BFOps.td |
| elm/core List → hybrid spines | The **spine representation**: `Tag_ConsChunk`/`Tag_ListBacking` (Heap.hpp:119-120) added beside plain cells; chunks are combinator-only, `::` untouched | `EcoListTemplate` rewrites cons-accumulator loops to scratch chunks (pass in EcoPipeline.cpp:81); Tier-B kernel shunts recognized by specialization origin, default-on (`Config.elm:324`) | −355.3M objects (−7.24%) (plans/chunked-list-representation.md:386) — and **wall-flat**, because chunk-form objects are 0.05% of promotion vs `Cons` 36.7% (Run H, benchmarks/tier2-opt.md:258-275) | plans/chunked-list-representation.md:372,386,646 |

Four lessons carried into every verdict below:

- **L1 — Replace the data structure and teach the compiler the shape; never port
  code.** Both precedents changed what the compiler *emits*, not just where the
  implementation lives. A line-for-line C++→Elm port keeps the same objects and the
  same walks and adds Elm's allocation per step.
- **L2 — The win mechanism must be allocation-removal on the *retained* population,
  or executed-work-deletion.** Chunked lists deleted 355M allocations and bought
  zero wall because none of them were promoted (Run H). K6 allocated +0.02% *more*
  objects and won −5.07% solver wall by retaining 29M fewer
  (benchmarks/tier2-opt.md:307).
- **L3 — NO-GO patterns.** (a) Fixed overhead added to a hot path: chunks-v1
  mandatory backings were +7.6% objects (plans/chunked-list-representation.md:372);
  the borrow-tune loop's standing rule is "only REMOVE allocation". (b) Retrofit
  transformation of an already-built structure: K5 eager interning rebuilt the graph
  it interned, +18.3% wall, REVERTED — transform at **construction or not at all**.
- **L4 — Demand dynamic heat evidence.** Static call-site counts (this section uses
  kernel-callsites.txt, 17,005 sites / 133 symbols) rank admissibility, not payoff;
  four consecutive tiers of static censuses collapsed at measurement.

One more precedent fact that de-risks two candidates below: **a C++ interpreter over
an Elm-declared ADT already ships and is green.** `writeEncoder`'s `EncoderTag` enum
(`BytesExports.cpp:93-105`) pins ctor indices to the declaration order of the real
Elm `Encoder` type (`Bytes/Encode.elm:46-57`). The coupling is unpinned by any test —
a golden test asserting ctor indices is a prerequisite for extending the pattern (R6).

### Candidate scorecard

| # | Candidate | Replacement shape | Retires | Mechanism | Verdict |
|---|---|---|---|---|---|
| 1 | elm/json | Elm decoder ADT (closure encoding) + streaming tokenizer op + direct string-writer encode | ~30 constructor exports, `runDecoder`, both nlohmann DOMs | Deletes 2 of 3 data copies + quadratic key transcode | **PURSUE** |
| 2 | elm/parser | Keep Elm `Parser`; add string index/length ops so the 7 kernels go gc-leaf or Elm | 4-7 Parser kernels as opaque calls | Statepoint deletion + per-call flatten removal | **PURSUE** (ops) / **REJECT** (Elm port) |
| 3 | Dict/Set | (a) HAMT (b) Int/String-specialized maps (c) construction-time hash-consing | — | (c) already shipped; (a) breaks semantics; (b) unproven heat | **REJECT** (a) · **EXPLORE** (b) · **DONE** (c) |
| 4 | JsArray/Array | Flat growable vector + transient builder | JsArray kernels (mostly already dead) | No retained-heap presence; no mechanism | **REJECT** (wholesale) |
| 5 | String → UTF-8-only | Drop the three UTF-16 heap forms | Widen machinery, dual-arm string ops | Executed-work-deletion (transcodes) + rep-count reduction | **EXPLORE** |
| 6 | VirtualDom/Browser | n/a — implementation, not re-implementation | — | — | out of scope (correctness backlog only) |

---

### 1. elm/json — PURSUE

**Current shape.** `Json.Decode.Decoder` is a phantom type on the Elm side
(`elm/json/1.1.4/src/Json/Decode.elm:62`: `type Decoder a = Decoder`); everything
real lives in `elm-kernel-cpp/src/json/JsonExports.cpp` behind 35 exports (grep
count of `Elm_Kernel_Json_*` definitions). All but five (`run`, `runOnString`,
`encode`, plus the incremental encode builders `addEntry`/`addField`, which cons
onto the ENC list — 2-3 allocations each, and `addEntry` invokes the
element-encoder closure, :1757) are **description constructors**: they allocate
one tagged `Custom` and never inspect a JSON value — `makeDecoder0/1/1i/2/2ip`
(JsonExports.cpp:464-539) and `buildMapDecoder` (:1456) are literally
`eco_alloc_with_roots(Tag_Custom, …)` + ctor + field stores, i.e. one
`eco.construct.custom` each (op at Ops.td:873). Beyond `addEntry`, only the
interpreter `runDecoder` (:552 onward) calls closures (:1117, :1167, :1198,
:1258).

Three verified defects make this the strongest wholesale case:

1. **`runOnString` materializes the same data three times** (JsonExports.cpp:1532-1552):
   a `std::string` copy of the input (:1534), a full nlohmann DOM (`json::parse`,
   :1537), then a complete GC-heap mirror (`jsonToHeap`, :305, invoked :1545) that
   `runDecoder` finally walks (:1548). Two of the three copies exist only to be
   traversed once. The GC mirror is live across the whole decode, so this is
   retained-heap pressure, not just nursery churn.
2. **`DEC_FIELD` is quadratic on record decoding.** Each field lookup transcodes the
   field name to `std::string` (:942-943) and then transcodes **each key in the
   object** to `std::string` in turn until the match (:959-960) — the whole key
   list when the field sits late or is missing. `DEC_MAP2..MAP8` run each
   sub-decoder over the same value (:1173-1262, `jvalEnc` reused at
   :1181/:1189/:1236), so an N-field record decode performs up to N full key-list
   transcode walks — O(fields × keys) worst case.
3. **`encode` rebuilds a DOM to print it**: `elmToJson` walks the `ENC_*` tree into
   a fresh nlohmann DOM (:1560) which is dumped (:1563-1565) and then copied into an
   ElmString (:1567).

**Replacement.** Decoders become a plain Elm ADT via the closure encoding
`Decoder (Value -> Result Error a)`. Two in-tree existence proofs: `Bytes.Decode`
is exactly this shape (`Bytes/Decode.elm:52`, combinators like `map` at :196), and
the compiler's own JSON layer — `Compiler.Json.Decode`, 1052 lines — already
implements `type Decoder x a = Decoder (AST -> Result (Problem x) a)` over a
pure-Elm parser (`compiler/src/Compiler/Json/Decode.elm:102-103`, `fromByteString`
:85) and is battle-tested by every self-compile. The phantom-GADT blocker the audit
identified (`Map2 : (a->b->c) -> …` has no Elm `type` encoding) is dissolved by the
closure encoding, at the documented cost of losing `runDecoder`'s tree
introspection — specifically the unboxed element-kind specialisation
(JsonExports.cpp:638-645, :749-754 area) and the flags/incoming-port decoder path,
which must keep a kernel-visible entry point.

What stays C++ (as 2-3 typed kernel ops, specs in the sub-dialects section):
a **streaming tokenizer** that yields heap values directly from the text without an
intermediate DOM; the **shortest-round-trip double formatter** (must stay bit-exact
with nlohmann `dump()` or the round-trip goldens in test/elm-json break); and the
string escape scanner. Encode becomes an Elm writer over the existing `ENC_*` tree —
or, better, over `Bytes.Encode`, which puts it on the already-fused BF path.

**Win mechanism.** Deletes copy 1 and 2 of the decode pipeline (allocation-removal,
partly retained), deletes the O(fields × keys) transcode walks
(executed-work-deletion), and converts ~30 opaque constructor calls into inline
`eco.construct.custom` — each such call today is a statepoint and a
gc-free-propagation poison site (the C2 prior: stamping/removing non-GC calls was
worth −1.72% wall at 5.27% function coverage, benchmarks/tier2-opt.md:162-176;
kernel calls poison 26,988 borrow-census occurrences, design_docs/borrow-inf-census.md:503).

**Honesty about heat.** The self-compiled compiler has **zero** static call sites to
`Json_run`/`Json_runOnString` and 37 raw occurrences (28 call forms) for the whole Json family (kernel-callsites.txt:52,72-101)
because it uses `Compiler.Json.Decode`. This candidate buys nothing on the
self-compile benchmark; its payoff is user programs (every Elm web/CLI app decodes
JSON), correctness, and deleting the nlohmann dependency from the hot path. Priors
in favor: none measured. Priors warning: none either — construction sites are
unchanged (no K5-shaped retrofit), and the decode path is a strict subtraction.

**Migration risk (M-L).** Ctor-index coupling Elm↔C++ during the transition (pin
with the R6 golden test); the flags decoder runs before user code and must keep a
kernel entry; `Json.Decode.Error` message strings are observable and pinned by
tests; `Json.Value` must remain opaque (it is the `CTOR_JSON_*` mirror today).
Stage it: encode-writer first (small, isolated), tokenizer second, decoder ADT last.

### 2. elm/parser — PURSUE the primitive-op shape; REJECT the Elm-source port

**Current shape.** Seven kernels in `elm-kernel-cpp/src/parser/ParserExports.cpp`,
all pure index scans over strings (`isAsciiCode` :130-133, `chompBase10` :283-295,
`consumeBase`/`consumeBase16`, `isSubString`/`findSubString` :240+, `isSubChar` HOF
via `eco_apply_closure_typed` :179). Every one funnels through
`parserFlatten` → `StringOps::ensureFlat` (five via `resolveString`, the two
substring scanners calling `parserFlatten` directly; :59-85), which
**allocates** for rope/slice sources — so none is gc-leaf today, and each call is a
statepoint.

**Why an Elm-source rewrite is non-viable.** Eco has six string representations
(Heap.hpp:80-112) and the dialect has **no string indexing op at all** — the string
group is only `string_literal`/`string.from_int`/`string.from_float`
(Ops.td:1076-1124). Without an indexing primitive, Elm source must use
`String.uncons`/`String.slice` per character: an allocation per step and O(n²) per
scan. REJECT.

**The winning shape** (this is L1 applied in reverse — the data structure is fine;
the compiler just cannot see into it): keep the Elm `Parser` library untouched, add
`eco.string.code_unit_at` + `eco.string.length` (op specs and lowering belong to the
sub-dialects section — not duplicated here). Then `isAsciiCode`, `chompBase10`,
`consumeBase`, `consumeBase16` become allocation-free gc-leaf ops or plain Elm over
those ops; `isSubString`/`findSubString` retain only their one result-tuple
allocation; `isSubChar` stays a HOF unless the compiler devirtualizes the handful of
real predicates (`Char.isAlphaNum` and literal-char lambdas — used at
`elm/parser/1.1.0/src/Parser/Advanced.elm:484`). Independent of placement, fix
`findSubString`'s naive O(n·m) double loop (ParserExports.cpp:255-273; the comment
at :254-255 claiming parity with `String.prototype.indexOf` is wrong) with
`memmem`/two-way.

**Win mechanism.** Statepoint deletion + un-poisoning of parser loops (the
gc-free-propagation prior above; parser predicates sit inside every
`chompWhile`-shaped loop of user parsers), plus removal of the per-call
`ensureFlat` flatten allocation. Zero `Parser_*` sites exist in the self-compile
(kernel-callsites.txt — no Parser rows; the compiler's own parser is
`Compiler.Parse.Primitives`), so like Json this is a user-program candidate — but it
is nearly free, riding entirely on ops the string sub-dialect wants anyway.

### 3. Dict/Set — REJECT the HAMT; the shipped lever is K6; narrow Int-map EXPLORE

**Current shape.** elm/core `Dict` is **pure Elm already** — a red-black tree
(`elm/core/1.0.5/src/Dict.elm:72-73`), no kernel involvement beyond polymorphic
compare (`Elm_Kernel_Utils_compare`, 296 static sites, kernel-callsites.txt:11).
So "re-implementation" here means replacing the data structure, and the question is
whether any replacement has a mechanism.

**(a) HAMT keyed by monomorphized key type — REJECT.** The blocking constraint is
semantic, not mechanical: Elm documents `Dict.foldl` as iterating "from lowest key
to highest key" (Dict.elm:509) and `toList` as "sorted by keys" (Dict.elm:601).
Hash-ordered iteration is user-visibly different. This compiler has *already been
bitten* by exactly this: when K4 introduced `Data.HashMap`, hash-ordered folds broke
codegen (an `eco.papCreate` referenced an SSA value outside its region) because
Dict fold order drives spec indices and type-registry numbering; the fix was to make
`Data.HashMap` **insertion-ordered by construction**
(compiler/src/Data/HashMap.elm:47,197-232). A public-Dict HAMT would need a sort at
every fold/toList — fixed overhead on a hot path, the L3(a) NO-GO shape. The
measured ceiling seals it: `_Utils_cmp` self time across the **entire** compiler is
≤1.94% (DEV-JS profile that stopped K3), and 5-field promoted Customs — the bucket
containing every RBNode (`RBNode_elm_builtin NColor k v l r`) plus everything else
5-ary — are 7.5% of promoted Custom ≈ 4.6% of total promotion (Run I,
benchmarks/tier2-opt.md:240). Both bounds are upper bounds on what any Dict
structure swap could touch.

**(b) Specialized Int/String maps — EXPLORE, narrowly.** design_docs/dict-usages.md
(summary table :190-228) found ~7 of 10 `Dict Int` usage categories carry
**contiguous 0..N keys** from sequential counters (SpecIds, NodeIds, expression
ids — the two largest categories, :195,206). Those are not hash-map candidates;
they are *array* candidates, which routes to candidate 4's cost model. The K4
warning applies to any such conversion: `Data.HashMap`'s Tuple2 bucket churn gave
back most of its allocation win (+93.8M Tuple2) — a replacement structure must not
allocate per operation what it saves per node. Gate any conversion on a
per-structure retention attribution (which Dicts own the promoted 5-field Customs),
not on site counts.

**(c) Construction-time hash-consing — ALREADY SHIPPED; this is the honest answer
to "make Dict faster".** K6 interned the dominant *key type* (MonoType) at
construction: solver −5.07% wall / −7.04% promotion / −13.2% RSS while allocating
+0.02% **more** objects (benchmarks/tier2-opt.md:307-325) — pure retention
mechanics, byte-identical output. Its sibling K5 (retrofit interning of the built
graph) was +18.3% wall, REVERTED. The transferable rule for this section: if a
structure replacement requires touching values after construction, it is a K5; if
it changes what construction produces, it can be a K6. Public elm/core `Dict`
cannot migrate (ordering contract); internal `Data.Map` sites (49 importing
modules) may migrate to the insertion-ordered `Data.HashMap` case-by-case, which is
precisely what K4/K6/K7 already did for the hot ones.

### 4. JsArray/Array — REJECT wholesale replacement

**Current shape.** elm/core `Array` is pure Elm: a 32-way bit-partitioned tree
(`shiftStep`, `elm/core/1.0.5/src/Array.elm:89-109`) over `JsArray` leaves. The
kernel story is further along than design_docs/array-optimisation.md asked for: the
dialect already has `eco.array.get/set/length/empty/singleton/push/slice/append_n`
(Ops.td:950-1074) with inline lowerings (`ArrayLengthOpLowering`
EcoToLLVMHeap.cpp:1219, `ArrayGetOpLowering` :1256), and the audit found 18 JsArray
C++ exports dead on direct paths. What remains hot at the boundary is the HOF
drivers: `JsArray_foldl` 365 sites, `initializeFromList_Int` 118,
`initialize_Int` 97, `foldr` 49 (kernel-callsites.txt:10,15,18,28).

**Who uses Array in the compiler** (verified by import grep, correcting the "driven
by Dict?" guess — Dict is an RB tree and allocates no arrays): the type checker's
IORef emulation stores its union-find state in `Array` fields
(`System/TypeCheck/IO.elm:79-82,123-126`, wrapped by `Data.Vector`/`Data.IORef`),
plus Monomorphize bookkeeping (State/Registry/Prune) and Graph. Every
`writeIORef` is an `Array.set` = a path copy through the 32-way tree.

**Verdict: REJECT (for now).** The mechanism test fails on the retention side:
`Tag_Array` (Heap.hpp:92) registers at only 0.1%/0.2% of promotion in the LH1
retained-heap table (352K/735K objects, 89 MiB subst; benchmarks/tier2-opt.md:285) —
`Custom` + `Cons` are 97.4% of promotion and nothing else exceeds 1.9% (Run H,
benchmarks/tier2-opt.md:258-275). A flat vector + transient builder (Roc/Koka
style) would be a large representation change (new tag or builder protocol, GC
walker changes, HEAP_BUILDER discipline) chasing a population the collector says it
would barely touch — the chunks-v1 shape of mistake (L3(a)). The costs that *are*
real — the closure trampoline in `foldl`/`initialize`, the per-element boxing —
are addressed by the incremental path array-optimisation.md already sketches
(steps 2-3: lower `Array.map`/`foldl` to `scf.for` over `eco.array.*` instead of
kernel HOF calls), which needs no new data structure. Reopen wholesale replacement
only if a per-tag census ever shows `Tag_Array` retention materially above
today's 0.1-0.2% or the type-checker's `Array.set` path-copy traffic surfacing
in the promoted set.

### 5. String → UTF-8-only — EXPLORE

The representation was already replaced once (HEAP_028-032; six concrete forms,
Heap.hpp:80-112), so the wholesale question left is dropping the three UTF-16 forms
entirely. What still forces u16, verified:

| Forcer | Anchor |
|---|---|
| `Char` is one UTF-16 code unit (`u16` heap, `i16` ABI) — `fromChar`/`cons`/`fromList` seed UTF-16 strings | Heap.hpp:384 (`ElmChar`); REP_ABI_001/CGEN_015; seeds table utf8-widen-attribution.md:44-54 |
| Lone surrogates are unrepresentable in strict UTF-8 (encode side is already de-facto WTF-8) | utf8-string-encoding-investigation.md:104-113 |
| Elm ordering is UTF-16 code-unit order ≠ UTF-8 byte order for astral-vs-`0xE000+` comparisons — `compare` needs a fixup | utf8-string-encoding-investigation.md:252-266 |
| Non-ASCII literals lower to `[N x i16]` globals | EcoToLLVMTypes.cpp:183-190 |

**What it buys.** (1) `Bytes_getStringWidth` — the **#6 hottest kernel symbol at
697 static sites** (kernel-callsites.txt:6), sizing every `BE.string` in artifact
serialization — is O(1) only on UTF-8 forms (BytesExports.cpp:319-322) and an O(n)
scan otherwise; UTF-8-only makes it unconditionally O(1). (2) It deletes the widen
machinery outright: measured widen work is ≈53M events / 138.6M units per
self-compile — 98.4% of the 1.7M counter-attributed events are mixed-encoding
`++`, and the 51.2M-event segment-chunk blind spot rides the same mixed-encoding
flattens (utf8-widen-attribution.md:9-33).
(3) Every dual-arm string op (append's 6×6 tag matrix, split/trim/indexes) loses
half its arms, and the parser/`code_unit_at` story simplifies to byte indexing plus
a unit counter. `String.length` stays O(1) regardless — `header.size` is the
logical UTF-16 unit count on every form including UTF-8 ones
(utf8-string-encoding-investigation.md:46, 144-152).

**Why EXPLORE and not PURSUE.** The cheap move captures most of the measured win
first: R1 of the widen-attribution report (seed constructors emit UTF-8 for ASCII
content — `fromChar`/`fromList`/`cons`) is projected from measurement to eliminate
>95% of widen work with no representation removal
(utf8-widen-attribution.md:96-105). If that lands and re-measurement still shows
material u16 traffic, UTF-8-only (concretely: WTF-8-only, keeping lone-surrogate
representability, plus the compare fixup) becomes a maintenance-driven
simplification — six tags → three — more than a wall play. It is a large,
invariant-heavy change (HEAP_025/HEAP_032 rewritten, every `forEachSegment`
consumer re-armed) and L2 gives it no retention story: strings transcode, they do
not double-retain.

### 6. VirtualDom / Browser — implementation, not re-implementation

62 of ~118 symbols in the browser/virtual-dom/file group are unimplemented stubs
(report 05 key finding 7), so there is nothing to "re"-implement and no perf
question to answer; this belongs to a product decision about targeting the DOM. What
does belong in this document is the **correctness backlog** the stubs carry:
(1) release builds compile with `-DNDEBUG` (CMakePresets.json:112-113), which erases
every `assert(false)` stub body and lets them fall through to
`HPtr::fromBits(0)` — silent null-HPointer corruption instead of a loud crash;
replace with an unconditional `eco_fatal`/abort. (2) `VirtualDom_node`/`keyedNode`
silently discard their children and attributes (`VirtualDom.cpp:70-72`) — they look
implemented while producing empty trees. (3) The XSS filter
`noJavaScriptOrHtmlJson` unconditionally returns `Just value`
(VirtualDomExports.cpp:218-224) — a security no-op with a working-sounding name;
its four sibling filters are real.

### Negative space — kernels that should NOT be re-implemented

- **Regex (SRELL).** A real, Unicode-aware engine — vendored SRELL
  (`RegexExports.cpp:13`), deliberately chosen because libc++ ships no `char16_t`
  regex_traits (`Regex.hpp:16-19`). The five matching ops are Hard-Infeasible in
  either Elm or the dialect (they need an engine), and static heat is negligible
  (≤5 sites each, kernel-callsites.txt:65-66,81-82,96). Fix in place instead: the
  never-freed pattern table keyed by a non-atomic counter (`RegexExports.cpp:36-46`),
  and the astral-input `Match.index` bug (`byteOffsetToCharIndex` counts code
  points where Elm promises UTF-16 units, :127-146).
- **Time / Http / Process / File services.** Their contract is
  KERNEL_TASK_IO_001/002 (invariants.csv:590-591): IO fires inside a `Task_Binding`
  when the **scheduler** steps it, with hand-rooted evaluator discipline. Syscalls
  and the async service threads cannot be expressed in Elm, and the pure
  Task-construction half is already near-optimal (the MVar evaluators capture
  payloads directly, `MVar.cpp:256-262` and the purity comment there). The right
  boundary work here is Task-builder attributes, not replacement.
- **MVar.** Same invariant (always-binding since the exemption-(d) deletion,
  invariants.csv:590), plus scheduler-internal blocking/wake semantics
  (`wakeWaiter`) that have no Elm-level equivalent. 164 static sites
  (kernel-callsites.txt:22,29,38,67,110) but every one is a Task description —
  the mechanism to improve them is the effects section's payload-capture shape,
  already the reference implementation.

### Recommendations

| # | Recommendation | Effort | Expected impact (grounded) | Verdict basis |
|---|---|---|---|---|
| R1 | elm/json encode side: Elm writer over the `ENC_*` tree (ideally via `Bytes.Encode` → BF), keep a bit-exact double-format kernel op | M | Deletes the encode-side DOM + one string copy per `encode` (JsonExports.cpp:1558-1569). User-program facing; no self-compile delta expected (0 hot sites) | §1 |
| R2 | elm/json decode side: closure-encoded Elm `Decoder` + streaming tokenizer kernel op; retire ~30 constructor exports and `runDecoder`; keep a kernel entry for flags/ports | L | Deletes 2 of 3 decode copies and the O(fields×keys) transcode (:942,:959,:1173-1262). Correctness + user programs; measured priors: none for, none against | §1 |
| R3 | elm/parser: ride the sub-dialect's `eco.string.code_unit_at`/`length`; gc-leaf the four pure scanners; `memmem` for `findSubString` | S | Statepoint + flatten-alloc removal in user parser loops; mechanism proven by the C2 prior (−1.72% wall from de-statepointing alone, benchmarks/tier2-opt.md:162-176) but unmeasured on parser workloads | §2 |
| R4 | Record Dict-HAMT as REJECTED (ordering contract Dict.elm:509,601 + K4 codegen-order incident + ≤1.94% cmp ceiling); do not revisit without new evidence | S (doc only) | Prevents a measured-dead-end retread | §3a |
| R5 | Contiguous-Int Dicts (SpecId/NodeId/expr-id categories, dict-usages.md:195-206) → `Array`/`Data.Vector` experiments, one structure at a time, gated on a per-structure retention attribution | M | Unproven; K4's bucket-churn giveback is the cautionary prior | §3b |
| R6 | Golden test pinning Elm-ADT ctor indices ↔ C++ enum (`EncoderTag` today, Json decoder tags if R2 proceeds) | S | De-risks the entire interpreter-over-Elm-ADT pattern both precedents rely on | precedents |
| R7 | String: land widen-attribution R1 (UTF-8 seed constructors) and re-measure before any UTF-8-only work; treat UTF-8-only as a representation-simplification RFC, not a perf item | S then L | R1 projected >95% widen-work elimination from exact attribution (utf8-widen-attribution.md:94-105); UTF-8-only additionally makes the 697-site `getStringWidth` unconditionally O(1) | §5 |
| R8 | VDom/stub correctness batch: unconditional aborts instead of NDEBUG-erased asserts, fix or loudly-fail `noJavaScriptOrHtmlJson`, delete the ~630 lines of dead stub TUs (`Bytes.cpp`/`Regex.cpp`/`Url.cpp`) | S | Correctness only; removes the silent-null failure mode from shipped binaries | §6 |

**Sequencing.** R4/R6/R8 are unblocked now. R3 is gated on the string sub-dialect
ops landing (same section, same release). R7's second half is gated on R7's first
half re-measurement. R1→R2 are ordered within themselves (encode first — smaller,
isolated) and gated on R6; they are *not* gated on census work, because their case
is correctness/user-programs, not self-compile wall — do not let them consume a
benchmark slot that can't detect them. R5 is gated on extending the LH1
instrumentation from per-tag to per-structure attribution (which Dicts/Arrays own
the promoted 5-field Customs); that census is the same artifact candidate 4 needs
before it could ever be reopened, and it should land before any structural Dict or
Array work is attempted — the alternative is re-running the tier pattern this
codebase has already paid for four times.

---

## 8. Kernel poisoning: inventory and removal (Q7)

**Q7: where exactly does the opaque kernel boundary tax the optimizer, and what does each tax cost to remove?**

"Poisoning" here means: a mechanism that is *forced to assume the worst* about a kernel
call because the callee is an attribute-free extern. The self-compiled compiler contains
**17,005 static kernel call sites across 133 symbols** (kernel-callsites.txt, summed), and
every one of them is opaque to six independent mechanisms at four different layers. The
mechanisms do not share a fact source, so each one re-assumes the worst separately — and
two of them (rows 5a/5b) assume *opposite* worsts.

### A.1 The inventory

| # | Mechanism | Where (anchor) | What it costs | What removal requires | Measured / estimated impact |
|---|---|---|---|---|---|
| 1 | **gc-free-leaf poison**: the CGEN_072 fixpoint poisons any function containing a call to a non-gc-leaf declaration; poison propagates callee→caller | `runtime/src/codegen/EcoBackend.cpp:1666` (`poison = true; // indirect call, or non-gc-leaf declaration`); CGEN_072 `design_docs/invariants.csv:636` explicitly lists "ALL kernel externs" as poison seeds | Caps stamped coverage at **2,372/44,967 fn = 5.27%** despite being default-ON (benchmarks/tier2-opt.md:166) | Stamp the audited never-GC kernel set `gc-leaf-function` on the LLVM declaration (H1); amend CGEN_072's "ALL kernel externs" clause | Prior: current 5.27% coverage bought **−1.72% wall / −2.06 MB text / stackmaps −5.17% / 11,149 sites** (tier2-opt.md:162-176). Lift from stamping: unknown until the census experiment below; direct-site bound is ~2,873 sites (§A.2) |
| 2 | **Statepoint + live-root inflation**: every non-musttail `eco.call` is a call safepoint; EcoGCPrepare appends the full live-root set as extra operands, and RS4GC statepoints the call and spills/reloads across it | `runtime/src/codegen/Passes/EcoGCPrepare.cpp:315-351` (Step 4, roots per call), `:125-131` (musttail excluded); root append `runtime/src/codegen/EcoOps.cpp:989-1005`; RS4GC's per-site predicate is `callsGCLeafFunction` (EcoBackend.cpp:1658) | Spill/reload traffic + stackmap metadata at every kernel call site. Stackmap mass is real money: capacity-hoist shipped −5.32 MB of pure stackmap metadata (memory: capacity-check-hoisting outcome), and C2's stamps cut stackmaps −5.17% (tier2-opt.md:172) | Same as row 1 — `callsGCLeafFunction` consults the callee declaration attr, so stamping removes the statepoint *at every call site of a stamped kernel* even inside unstamped callers. Alternative: conversion to dialect ops (separate section) | Bound: the row-1 stampable set covers ~2,873 of 17,005 kernel sites (16.9%); each loses its statepoint + root operands. Wall expectation: C2-shaped (see §B expectations) |
| 3 | **Allocation-group barrier**: `isGroupBarrier` treats *every* call as a barrier ("D3: conservative"), splitting the coalesced allocation groups that get one fast/slow capacity diamond for the whole group | `runtime/src/codegen/Passes/EcoGCPrepare.cpp:110-121`; groups → one diamond `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp:23-26`, lowered at `Passes/EcoToLLVM.cpp:245` | A kernel call inside a construction run splits one group into two → **two** capacity checks (two diamonds) where one sufficed | A per-callee `cannotGC` bit at the MLIR level: emit `eco.kernel_cannot_gc` (unit attr) on the kernel `func.func` decl next to `is_kernel` (emitted at `compiler/src/Compiler/Generate/MLIR/Functions.elm:1999`), and have `isGroupBarrier` resolve the callee symbol and pass calls whose callee carries it (needs a cached symbol lookup in the pass; the pass is module-walk per function, EcoGCPrepare.cpp:156-163). Root-liveness stays correct: Step 4 runs after grouping in the same pass | Unmeasured. Mechanically bounded by how often a stampable kernel call lands *between* two groupable allocations in one block; count it with a one-off census in EcoGCPrepare before building the plumbing |
| 4 | **Borrow-inference poison**: unknown kernels force all heap args owned (`poisonArgs RKernel`) | `compiler/src/Compiler/GlobalOpt/Borrow/Constrain.elm:883-908` (KernelSigs hit at :884-888, poison at :893); whitelist discipline KernelSigs.elm:14-16 | Phase-2 baseline **poisonedByKernel = 26,988** (design_docs/borrow-inf-census.md:503); after the 33-row B3 KernelSigs table (`Borrow/KernelSigs.elm:54-165`): **20,508**, with `kernelSigHits = 7,415`, `kernelDefaultedHeapCalls = 11,165` (borrow-inf-census.md:1152-1164) | Widen KernelSigs. But the remaining top defaulted names are *genuine owners* — `List.cons` = 4,191, `Utils.append` = 3,274, `Scheduler.*` (borrow-inf-census.md:1165-1167) — which no signature can un-own; the un-audited tier is single-to-double digits | **Honest framing: analysis quality only, no wall win.** The oracle is census-only and default-OFF (`Config.elm:323`, `borrow = { enabled = False, … }`), and the borrow-consumers series concluded the static pool is dynamic-RC-1-only (memory: borrow-oracle-consumers plan, Runs K/L/M triangle) |
| 5 | **Mono-level contradiction**: (a) `isPureExpr` says every kernel call (indeed every call) is impure, blocking dead-let elimination; (b) `CafHoist`/`CafDedupe` assume every non-`Debug` kernel expr is pure enough to hoist/merge; (c) `computeCost` scores `MonoVarKernel` at 1 | (a) `compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm:5114-5116` (`MonoVarKernel → False`), `:5131-5133` (`MonoCall → False`), consumed by the dead-binding gate at `:4780`; (b) `CafHoist.elm:392-393` (`hasDebug = home == "Debug"` is the *entire* effect model), `CafDedupe.elm:105-116` merges structurally equal specs with no purity check (both default-off, `Config.elm:321`); (c) `MonoInlineSimplify.elm:1230-1231` | (a) a dead `let w = String.length s` is unremovable; (b) an unsound-in-principle assumption shipping on a string compare; (c) the inliner cannot tell a comparison that lowers to 2 instructions from an `append` that allocates a rope — a body of N kernel comparisons looks expensive (blocks inlining that would unlock downstream opts) while a body wrapping one allocating kernel call looks cheap (cost 5+1, `:1245-1246`) — distortion in both directions | All three consult the **facts table** (§B.0): (a) `isPureExpr` returns True for calls whose callee has the `pureElm` bit (H4); (b) CafHoist/CafDedupe *keep* their behavior but justify it from the table instead of `home == "Debug"` — one line, details in the attributes section (parallel, not duplicated here); (c) cost from the table's lowering class (H4) | (a) enables Mono DCE of dead pure kernel calls — unmeasured, census-able for free during C1 of the CSE plan; (c) any new cost constants must be A/B'd — inliner-threshold changes have historically large blast radius |
| 6 | **CSE/folding absence**: no MLIR CSE or canonicalizer pass, no `hasFolder`/`hasCanonicalizer` on any op, no Elm-level CSE, and LLVM CSE is blocked because EarlyCSE/GVN only merge calls attributed `readnone`/`readonly` — kernel declarations carry nothing | Pipeline: `runtime/src/codegen/EcoPipeline.cpp:82-90` (M4 removal comment; commented-out canonicalizer at :90); zero folders: grep of `Ops.td` for `hasFolder|hasCanonicalizer` returns nothing; Elm level: `plans/cse-pure-calls.md:3` (NEW, **UNSIZED**), whose carve-out 3 (`:82-86`) waits on exactly the kernel purity classification this document supplies | Repeated pure work is never merged at any level | H2 (MLIR CSE), H3 (Mono CSE), H1+H6 (attributes that let LLVM/MLIR see purity) | **Do not misread M4.** M4's canonicalizer removal left the *functional output* byte-identical but moved the exe +~0.28% (EcoPipeline.cpp:83) — the pass was folding only upstream-dialect (arith/scf) IR, since no Eco op has a folder or canonicalizer; M4 measures the compile-time budget (~0.5 s MLIR phase), not CSE's value. The K6 prior (§B) is the evidence that redundancy elimination can pay |

### A.2 Row 1 in detail: the stampable set and the census experiment

> **EXECUTED 2026-08-09** — the experiment below was run
> (plans/kernel-call-census.md §Results). Measured: baseline reproduces Run M
> exactly (2,372/44,967 = 5.27%, 11,149 sites); the 20-declaration pilot
> lifts it to **2,518/44,967 = 5.60% (+146 functions), 13,078 sites
> (+1,929, +17.3%)**; binary −660,824 B (−1.01%; −637,568 B of it
> `.llvm_stackmaps`, which at 23.0 MB is *larger than the entire .text*).
> Wall on cold Stage 7a: **FLAT** (330.87s vs 330.90s, interleaved 2×2,
> outputs byte-identical), despite the pilot set covering **64.1% of the
> 3.68B dynamic kernel calls**. Read: the stamp's value is size + enabling
> (group merging, hoist runs, CSE/DCE prerequisites), not direct wall — the
> wall lever is deleting the *calls* (the 1.95B `Utils_compare` Dict
> machinery above all). The env-gated pilot plumbing
> (`ECO_KERNEL_GCLEAF_PILOT`, `EcoToLLVMInternal.h`) is in-tree for the real
> change to reuse.

The poison seed classes at the fixpoint (EcoBackend.cpp:1638-1674) are: interposable
bodies, EH constructs, indirect calls, and calls to non-gc-leaf *declarations* — the
kernel externs are the only seed class that is large, enumerable, and partly false.
The audit files classified every symbol; re-verified highlights that **provably cannot
trigger GC** (they never touch the Eco heap allocator; C++-heap use is irrelevant to
gc-leaf):

| Symbol | Sites (kernel-callsites.txt, verified vs eco-compiler.txt.mlir) | Why safe (verified anchor) |
|---|---:|---|
| `Elm_Kernel_Utils_equal` | 1,357 | No Eco allocation on any path; embedded-Bool results; `dictEq` walks with `std::vector` (elm-kernel-cpp/src/core/Utils.cpp:514-733). ⚠ carries an `fprintf` trace on the tag-mismatch path (Utils.cpp:550-555) — a side effect, but not a GC hazard |
| `Elm_Kernel_Utils_compare` | 296 | Returns one of three pre-allocated rooted singletons (Utils.cpp:451-457); singleton allocation happens once at init (Utils.cpp:35-39) |
| `Utils_lt`/`notEqual`/`gt`/`ge` | 80/63/41/3 | Same `cmp`/`eqHelp` cores |
| `Elm_Kernel_Bytes_getStringWidth` | 697 | O(1) UTF-8 fast path; worst case one C++ `std::u16string` materialization, zero Eco allocation (elm-kernel-cpp/src/bytes/BytesExports.cpp:309-366) |
| `Elm_Kernel_Bytes_decodeFailure` | 152 | Returns a constant (audit 04 row; BytesExports) |
| `String_{length,startsWith,contains,endsWith}` | 102/48/7/5 | O(1) length load / memcmp tiers, no allocation (audit 02, StringOps.hpp:688-714 for startsWith) |
| `Bytes_width`, `Char_toLower`, `Regex_infinity` | 15/4/3 | Trivial (audit 01/04; Char.cpp:76-80 is an ASCII range test) |
| **Total** | **≈ 2,873 (16.9% of 17,005)** | |

**R1 (effort S): stamp this set and measure by census before claiming anything.**
The one-line-per-symbol precedent already exists in-tree: `runEcoBackend` stamps
`eco_scratch_mark`/`eco_scratch_push_*` declarations with `addFnAttr("gc-leaf-function")`
at EcoBackend.cpp:2511-2515. The experiment:

1. Baseline: `ECO_GCFREE_LEAF=c` self-compile — census mode prints
   `numFree/numDefined` + de-statepointed sites without mutating anything
   (EcoBackend.cpp:107-116 for the mode parse, :1720-1725 for the report).
2. Prototype: add the table above as a static name list stamped just before
   `propagateGcFreeLeafAttrs` (called at EcoBackend.cpp:2565-2568); re-run the census.
3. The delta in `numFree` is the transitive coverage lift; the delta in `numSites` is the
   direct statepoint removal. Only then A/B wall (Stage 7a, two rounds, per the tier-2
   protocol).

Two honest caveats. First, a function is stamped only when *all* of its statepointable
calls are leaf — callers of `Utils_equal` frequently also call `List_cons` (4,158 sites)
or `Utils_append` (3,465), both genuinely allocating, so the *transitive* lift may be
much smaller than the direct-site count suggests; that is exactly what step 3 measures
before any wall run. Second, the direct effect does not need the caller stamped at all:
`callsGCLeafFunction` is per-call-site (EcoBackend.cpp:1658 uses the same predicate RS4GC
does), so all ~2,873 sites lose statepoint + roots the moment the declarations are
stamped.

**Second-order effect: capacity-check hoisting gets longer runs.** The transform
requires gcFree Stamp mode (EcoBackend.cpp:2527-2541 warns "requires ECO_GCFREE_LEAF
(stamp mode)" when misconfigured; CGEN_074, invariants.csv:638), and inside it a
non-gc-leaf declaration is ⊤-poison for coverability (EcoBackend.cpp:1889 `// indirect,
or non-leaf declaration`) *and* a run breaker in the straight-line scan
(EcoBackend.cpp:2153-2155: non-leaf ⇒ `flushRun()`; leaf calls are "transparent").
Stamped kernels therefore stop ending hoisted runs and stop excluding their callers from
coverage. The soundness obligation is stronger here than for RS4GC: gc-leaf does NOT
imply bump-state-transparent (EcoBackend.cpp:1741-1750, `isHeadroomBreaker`; CGEN_074's
"gc-leaf does NOT imply bump-state-transparent" clause) — the table may only carry the
bit for kernels that allocate *nothing*, which the set above satisfies (zero Eco
allocation, so they never touch `NurseryBump{ptr,end}`). A kernel that allocates via any
fast path must never get the bit. CGEN_073's selective frame pointers also compound
mildly: fewer statepointed frames ⇒ more functions release `rbp` (invariants.csv:637).

### A.3 Rows 4–5: the same fact, three private copies

The deep problem rows 4 and 5 share with row 1 is not any single conservative default —
each default is locally sound — but that **three layers hold three private, mutually
inconsistent effect models**: LLVM (nothing on the declarations), Mono (`isPureExpr`
all-impure vs CafHoist `home == "Debug"`), and the borrow oracle (KernelSigs, the only
audited one, 33 rows, whitelist-disciplined). The removal for all of them is one
authoritative **kernel facts table** (§B.0), not three patches.

## 9. Harvesting Pure traits (Q8)

**Q8: the dialect already declares purity — what would it take for anything to consume it?**

The state of play: **100 of 132 `Eco_Op` defs in Ops.td carry `[Pure]`** (counted by
parsing the trait lists; the 32 non-Pure ops are call/papExtend/make.closure —
papCreate/papCreateGroup DO carry `Pure` despite allocating (Ops.td:1169-1170,
1223-1224) — plus the allocate-family, array mutators, string.from_int/from_float,
globals, RC ops, and control flow).
**Nothing consumes the trait.** There is no `createCSEPass()` or `createCanonicalizerPass()`
anywhere under `runtime/src/codegen/` (sole grep hits are M4's comment,
EcoPipeline.cpp:88-90), no op declares `hasFolder`/`hasCanonicalizer`, and `eco.call`
carries no purity information at all — its only interfaces are `SymbolUserOpInterface`
and `Eco_GCRootCarrierOpInterface` (Ops.td:1129-1132). One hundred Pure declarations,
zero readers.

### B.0 The prerequisite: one kernel facts table

Every harvest item below consults the same source: a per-symbol table with independent
bits — `cannotGC` (gc-leaf; implies nothing about C++-heap use), `allocatesEco`,
`readsHeap`, `pureElm` (CSE/DCE-admissible under Elm semantics), `hof`, `taskBuilder`
(KERNEL_TASK_IO_001, invariants.csv:590 — Task constructors allocate and must never be
`cannotGC`), `noreturn`. Unlisted symbol ⇒ all-worst-case, the KernelSigs whitelist
discipline (KernelSigs.elm:14-16). Prototype home: a C++ name list at the EcoBackend
choke point (H1); durable home: the Elm side next to KernelSigs, emitted onto the kernel
`func.func` declarations as attributes (Functions.elm:1999 already emits `is_kernel`
there) so Mono passes, EcoGCPrepare, and the LLVM lowering all read one source. Ownership
and schema details live in the attributes section — §6.C1's `KernelFacts` record is normative, and the bit names used here are shorthand projections of it; this section owns *who
consumes it*.

### B.1 The harvest plan

**H1 (effort S) — stamp gc-leaf from the facts table.** The Tier-0 item; §A.2's R1
verbatim. Smallest diff (a name list + `addFnAttr` at EcoBackend.cpp:2511-2515's
precedent site), measurable by census alone before any wall run, and it feeds rows 1, 2,
and the capHoist second-order effect simultaneously. Gates: E2E `--target full`,
heap-validate, bootstrap byte-identity — plus amending CGEN_072's "ALL kernel externs"
wording (invariants.csv:636) *in the same change*, since the invariant as written
forbids exactly this.

**H2 (effort M) — MLIR-level CSE + first folders.** Add
`pm.addNestedPass<func::FuncOp>(mlir::createCSEPass())` at the M4 slot
(EcoPipeline.cpp:90) — after the Eco→Eco stage, before EcoGCPrepare. Placement is
load-bearing twice over: (a) roots are appended to carrier ops *by* EcoGCPrepare
(EcoOps.cpp:995-1005 mutates operands + `eco.gc_roots_count`), so CSE must see ops
before their operand lists diverge on root sets; (b) the M4 comment's own safety argument
(EcoPipeline.cpp:84-87) — pre-GC IR changes make liveness *more conservative* at worst,
and over-rooting is the safe direction. The 100 Pure ops CSE for free; nested adjacent
passes merge into one parallel sweep over the ~64k functions (EcoPipeline.cpp:115-118).
Compile-time must pay for itself against the M4 budget: M4 deleted a canonicalizer for
~0.5 s of MLIR phase (EcoPipeline.cpp:82-83), so measure the MLIR-phase delta and Stage
7a wall on the self-compile the same way. Folder candidates, sized against the corpus
(my scan of the 972,418-line eco-compiler.txt.mlir, per-function SSA scoping):

| Candidate folder | Corpus evidence | Verdict |
|---|---|---|
| `eco.get_tag` of `eco.construct.*` | 3 of 20,415 `get_tag` ops fed by a same-function construct | Elm-side codegen already avoids it — **skip** |
| `box(unbox(x))` / `unbox(box(x))` | 0 pairs in 2,961 box / 2,986 unbox ops | Nonexistent — **skip** |
| `eco.project.*` of same-function `eco.construct.*` | **2,965 of 158,451 projections (1.9%)** | The only folder with a real pool; a `fold` that forwards the constructed field operand (and can render constructs dead for CSE/DCE to collect). Sample-quality count — verify kind-match and block-locality during implementation |

Gates: full E2E + self-host byte-identity is *expected to break* (output changes are the
point) — so the gate is E2E + heap-validate + bootstrap Stage-comparison, with the
retention counters watched (C-R1 below).

**H3 (effort L, census-gated) — Mono-level CSE.** `plans/cse-pure-calls.md` (UNSIZED,
census C1 first) is unblocked by the facts table: its carve-out 3 explicitly waits on "an
explicit purity classification of kernel names, defaulting to impure for anything
unlisted" (cse-pure-calls.md:82-86) — that is the `pureElm` bit. Its design rule
restated in one line: **C-R1 — prefer near CSE to far CSE; a merge that spans a
definition body creates a long live range and must justify itself against retention**
(cse-pure-calls.md:108-114) — this codebase's wall tracks retention and deleted work,
not allocation counts (K6: −5.07% solver wall at +0.02% objects; K5 eager interning
+18.3% REVERTED).

**H4 (effort S) — Mono-level DCE.** Let `isPureExpr` consult the facts table for
`MonoCall _ (MonoVarKernel …) args` (today `MonoVarKernel → False` at
MonoInlineSimplify.elm:5114-5116 and `MonoCall → False` at :5131-5133), so the dead-let
gate at :4780 can drop a dead `String_length`. Two obligations travel with it: the
Debug.log ordering policy the CSE plan records as *owed and never written*
(cse-pure-calls.md:67-77) must be written first — DCE of a call that transitively logs
changes observable output exactly as CSE does; and `computeCost`'s `MonoVarKernel = 1`
(:1230-1231) should take its cost from the table's lowering class at the same time, with
any constant change A/B'd separately (inliner thresholds are high blast radius).

**H5 (one line) — LLVM-level post-RS4GC attribute stamping** (`memory(read)`/`nofree`
etc. on kernel declarations, enabling EarlyCSE/GVN over kernel calls): owned by the
attributes section (parallel); it consumes the same facts table and inherits the
EcoToLLVMRuntime.cpp:884-891 prohibition below.

**H6 (effort M) — give `eco.call` a purity channel.** An optional unit attr (e.g.
`eco.pure`) mirrored from the facts table at emission, plus a
`MemoryEffectOpInterface` implementation on `Eco_CallOp` that reports no effects *iff*
the attr is present — then upstream MLIR passes (H2's CSE, future LICM-like motion, the
row-3 `isGroupBarrier` relaxation) consult one place instead of growing per-pass name
lists. Interaction to respect: `eco.call` is a `GCRootCarrier` (Ops.td:1129-1132) whose
operand list is *mutated* by EcoGCPrepare's root append (EcoOps.cpp:995-1005) — every
purity-consuming pass must run before EcoGCPrepare, and the attr must never license
motion after it. Do not blanket-mark `eco.call` Pure: most calls allocate, HOF kernels
run closures, Task builders capture (KERNEL_TASK_IO_001).

### B.2 What NOT to do

- **No motion-enabling attributes pre-RS4GC on barrier-like calls.** The standing
  prohibition at EcoToLLVMRuntime.cpp:884-891: the slot-cast barriers are gc-leaf ONLY —
  `memory(none)`/`speculatable`/`willreturn` would let a pre-RS4GC pass move them across
  a statepoint and reconstruct the raw-i64 crossing they exist to prevent. The same
  reasoning bounds H5: purity attrs on kernel declarations are a *post*-RS4GC affair.
- **No blacklist-shaped table.** Unknown symbol ⇒ worst case, always (KernelSigs.elm:14-16
  precedent). A forgotten effectful kernel under a whitelist is a wrong answer; under a
  blacklist it is a miscompile.
- **No re-litigating M4 as anti-CSE evidence** (§A.1 row 6): the byte-identity there
  was of the *functional output* only (the exe moved +~0.28%, EcoPipeline.cpp:83) —
  it proves the canonicalizer did no Eco-level folding, nothing more.

### B.3 Expectations, calibrated against the priors

Set expectations by the two shapes this series has actually measured. **H1 is the
C2-shaped bet**: identical alloc/minors/majors/output, pure code quality — C2 paid
−1.72% wall / −2.06 MB for 5.27% coverage (tier2-opt.md:162-176), and the marginal lift
from kernel stamping lands on top of the same mechanism. But the preserve-cc arc is the
cold shower in the same family: provably-correct code-quality wins on non-allocating
paths measured wall-FLAT (tier2-opt.md:182-201, Run L "FLAT; NCSR machinery reverted";
Run K FATAL at :202) — so H1 may be flat too, and the census numbers must be collected
*before* the wall run so a flat result still buys the capHoist/coverage facts. **H2/H3
are the K6-shaped bet**: K6's hash-consing deleted duplicate work and moved solver wall
−5.07% via retention, not allocation count (plans/mono-comparable-key-optimization.md:11-14)
— CSE generalizes that mechanism, C-R1 guards its trap. **H4/H6 are enabling
infrastructure**: no direct wall claim; their value is unblocking H2/H3 and ending the
row-5 contradiction.

### B.4 Sequenced roadmap

| Phase | Items | Gates |
|---|---|---|
| 0 | Facts table (prototype: C++ name list; schema per attributes section) + CGEN_072 amendment + Debug-ordering invariant note (owed per cse-pure-calls.md:67-77) | Review of table rows against kernel sources (audit files 01–07 as the worklist); invariants.csv updated in the same change |
| 1 | **H1** stamp + `ECO_GCFREE_LEAF=c` before/after census; then wall A/B | E2E `--target full`, heap-validate, bootstrap byte-identity (flag-off arm), census deltas recorded in benchmarks/tier2-opt.md |
| 2 | **H2** MLIR CSE at the M4 slot + the `project`-of-`construct` folder | MLIR-phase compile-time delta vs the ~0.5 s M4 budget; Stage 7a wall; retention counters (majors/promotion) watched per C-R1 |
| 3 | **H4** isPureExpr + computeCost from the table (small, independent) | E2E; separate A/B for any cost-constant change |
| 4 | **H3** Mono CSE — run cse-pure-calls.md C1 census first, sized by its result | The plan's own gates; C-R1 distance bound |
| 5 | **H6** `eco.call` purity attr + row-3 `isGroupBarrier` relaxation (needs the same MLIR-side bit) | Group-split census in EcoGCPrepare first; E2E + heap-validate |
| — | **H5** LLVM declaration attrs | Owned by the attributes section |

Dependency spine: 0 → 1 is independent of 0 → {3,4}; 2 needs nothing from 0 (the Pure
traits already exist) but shares gates with 5; 5's barrier relaxation reuses 0's table
via the MLIR attr. Phase 1 is deliberately first among the measured items: smallest
diff, census-measurable without a wall run, and every later item consults the table it
forces into existence.

---

## Appendix A — Evidence index

Per-symbol classification tables (agent audits, 2026-08-09; every row carries
file:line anchors):

| File | Scope |
|---|---|
| `audit-01-basics-bitwise-char-utils.md` | Basics, Bitwise, Char, Utils, Order singletons (84 symbols) |
| `audit-02-string.md` | String + StringOps/Utf8 runtime support (33 symbols) |
| `audit-03-list-jsarray.md` | List, JsArray + ListOps (57 symbols) |
| `audit-04-json-url-parser-regex-bytes.md` | Json, Url, Parser, Regex, Bytes (77 symbols) |
| `audit-05-elm-effects.md` | Scheduler, Platform, Process, Debug, Time, Http, File, VirtualDom, Browser (~118 symbols) |
| `audit-06-eco-kernel.md` | All of `eco-kernel-cpp/` (53 symbols) |
| `audit-07-runtime-surface.md` | Runtime support symbols callable from generated code |
| `audit-08-dialect-and-blocked-opts.md` | Dialect op inventory + blocked-optimization analysis |
| `callsite-census-self-compile.txt` | Raw static call-site counts (17,005 sites, 133 symbols) |

## Appendix B — Correctness backlog found during the audit

Not part of this design, but several items **block** design claims (marked ⛔)
and should be fixed first. File separately.

| # | Finding | Anchor | Blocks |
|---|---|---|---|
| B1 | `Platform_sendToSelf`/`sendToApp` perform the send at construction time — `KERNEL_TASK_IO_001` violations; a shared/memoized Task sends once, not once per fulfilment | `PlatformRuntime.cpp:574`, `:549` | — |
| B2 | `Process_spawnProcess` returns `Tag_Record` where Elm destructures a `Tuple2`, field order also swapped vs the JS kernel | `Process.cpp:148-161` vs `Eco/Process.elm:84` | — |
| B3 | `Eco.File.lock`/`unlock` are silent no-ops — `withFileLock` provides no mutual exclusion natively | `File.cpp:431-432` | — |
| B4 | `Console.write` silently drops output for handles ∉ {1,2}, contradicting the `spawnProcess` stdin-pipe docs | `Console.cpp:66-74` | — |
| B5 | `fprintf(stderr)` + non-atomic `static int` **inside `Utils::equal`**; also `depth>100 → true` cutoff makes `==` and `compare` able to disagree | `Utils.cpp:550-555`, `:560` | ⛔ gc-leaf + purity claims for `Utils_equal` (§5, §7) |
| B6 | `List_sortBy` comparator violates strict weak ordering (`cmp` returns −1 when `!a` before testing `b`) → UB in `std::stable_sort` | `Utils.cpp:305`, `ListExports.cpp:730` | — |
| B7 | String semantic divergences from elm/core, none E2E-covered: `toInt "+5"` → `Nothing`; `toFloat " 1.5"`/`"0x10"` accepted; `indexes "" s` → `[0..n]`; `reverse` corrupts surrogate pairs | `StringOps.hpp:1145`, `:1174`, `StringOps.cpp:780-804` | ⛔ Elm-source String HOF migration must not bake these in (§4, §6) |
| B8 | `VirtualDom_noJavaScriptOrHtmlJson` unconditionally returns `Just value` — an XSS filter that filters nothing; `node`/`nodeNS` silently discard children/attrs | `VirtualDomExports.cpp:221-224`, `VirtualDom.cpp:71-72,93-94` | — |
| B9 | `-DNDEBUG` in the `release` preset erases stub `assert(false)`s — stubs return `HPtr 0` and callers dereference; silent in shipped binaries | `CMakePresets.json:112-113` | — |
| B10 | `Regex_infinity` returns `double`, consumed as `Int` (xmm0 vs rax); `Bytes_getHostEndianness` returns `HPtr::fromBits(0|1)` — a "pointer" to address 0/1; regex id counter non-atomic; `Match.index` counts UTF-8 code points where Elm specifies UTF-16 units | `RegexExports.cpp:171`, `BytesExports.cpp:303`, `RegexExports.cpp:36-46,127-146` | — |
| B11 | `Basics.modBy` **throws** on 0 where the intrinsic returns 0; `idiv`/`remainderBy` UB-on-zero vs guarded intrinsics; `Utils.cpp:214` `assert(false)+__builtin_unreachable()` is UB under NDEBUG | `Basics.cpp:96`, `Utils.cpp:214` | ⛔ attribute rows must record the divergence (§5) |
| B12 | Documentation rot: 22 stale eager-semantics comments + 5 `uint64_t`-vs-Task type lies in `eco-kernel-cpp/.../KernelExports.h`; `kernel-task-deferral.md` still lists exemptions deleted by `invariants.csv:590` | audit-06 §findings 6–8 | — |
| B13 | `eco_crash` missing `noreturn`; 24 dead runtime declarations (`eco_tuple2_get_*` family) force-materialized but never emitted | audit-07 | — |
| B14 | `Url.percentEncode`/`percentDecode` diverge from `encodeURIComponent` in three ways; the *dead* `Url.cpp` implementation is the correct one | `UrlExports.cpp:24-30,88-90,96` | — |
| B15 | Possible reentrancy hazard: `takeBindingEvaluator` holds a reference into `s_mvars` across `callClosure1` while `dropBody` can `erase` it (**unverified** — flagged, not asserted) | `MVar.cpp:198-201` vs `:332` | — |

## Appendix C — Related documents

- `design_docs/theory/intrinsics_theory.md` — the existing intrinsic mechanism this design extends.
- `design_docs/theory/kernel_abi_theory.md` — ABI modes, per-instance kernels, KERN_006.
- `design_docs/theory/kernel-task-deferral.md` — Task-deferral invariant (needs regeneration; see B12).
- `design_docs/fused-bytes-compilation.md` — the BF precedent.
- `design_docs/kernel-closure-lookthrough.md` — sketch for de-virtualizing kernel-as-closure uses (complements §3's PAP finding).
- `design_docs/borrow-inf-census.md` — borrow poisoning numbers and the KernelSigs seed table.
- `plans/cse-pure-calls.md` — Mono-level CSE, blocked on the purity classification this document supplies.
- `plans/gc-free-function-propagation.md`, `plans/capacity-check-hoisting.md` — the shipped consumers of gc-leaf knowledge.
