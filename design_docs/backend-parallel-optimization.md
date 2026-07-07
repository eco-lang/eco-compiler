# Parallelizing the LLVM backend optimizer — the "disable IPO, one module per function" idea

**Status:** analysis / design exploration (2026-07-06). No code changed.
**Scope:** the LLVM half of the AOT backend — RS4GC → `-O2` opt pipeline → object
emission → link — and specifically whether disabling inter-procedural
optimization (IPO) to make optimization embarrassingly parallel is worth it.
**Companion:** `design_docs/backend-pipeline-performance.md` (the earlier pass that
parallelized *object emission* and cut the self-host `-O2` lower 222 s → ~82 s).

---

## 1. TL;DR / recommendation

The idea is aimed at the right target. After the earlier perf pass, **the single
dominant serial cost in the backend is the whole-module `-O2` optimization
pipeline: ~51 s, ~59 % of the backend, running effectively single-threaded**
(measured below). Object emission is already parallel; opt is not. Making opt
parallel is the remaining big lever.

But the specific framing — *"disable all IPO so each function is its own module"* —
needs three corrections before it becomes a good plan:

1. **Granularity: don't do one-function-per-module.** 85,686 modules × (bitcode
   round-trip + fresh `LLVMContext` + fresh `TargetMachine`) is pure overhead. The
   real proposal is **N ≈ cores partitions**, which the existing `SplitModule`
   machinery already produces.
2. **"Disable IPO" is not free here — it is a large, currently-realized quality
   loss.** For executable output the module is fully internalized + GlobalDCE'd
   *before* opt, so the produced binary today gets **100 % whole-module IPO**
   (inliner + IPSCCP + GlobalOpt + argpromotion + DCE). Disabling IPO regresses
   that to ~1/N (per-partition) or 0 (fully off). **The produced binary is the
   eco compiler itself**, so this is a recursive tax on every future compile. This
   is exactly why the earlier pass deferred "per-partition opt" (B2b) with the note
   *"would degrade produced-binary runtime (it is the compiler)."*
3. **"Disable all IPO" over-reaches even if you accept losing the inliner.**
   IPSCCP and GlobalOpt are *especially* valuable on eco's output because
   monomorphization creates many now-constant specializations for them to
   propagate. Throwing them away costs real code quality beyond inlining.

**Net recommendation — a tiered plan, not a single switch:**

| Tier | What | IPO | Quality trade | When |
|---|---|---|---|---|
| **0** | **Hoist the split *policy* into the shared `EcoBackend` layer** so every driver (`eco make`/`EcoNativeDriver`, `eco-boot`, `ecoc`) gets parallel emission — today only `eco-boot` has it | full whole-module | **none** | do first, free |
| **1 (dev / fast)** | Split before opt, run a **no-inline function-simplification pipeline** per partition | off | large, but irrelevant for throwaway dev builds | `eco make` iteration, `-O1`/dev default |
| **2 (release)** | **ThinLTO** (reuse LLVM's `LTO`/`ThinLTOCodeGenerator`): split before opt, summary → combined index → import hot/small callees as `available_externally`, then parallel per-partition `-O2` | ~most preserved | small | self-host + user release builds |
| **2′ (release, simpler)** | Codegen-units + **physical** replication: per-partition `-O2` plus copying `alwaysinline` glue bodies into every referencing partition (hand-rolled intra-module ThinLTO) | partial | measurable; must *physically* replicate — SplitModule won't (§6.4) | stepping stone to measure before Tier 2 |

Tier 1 *is* the user's idea, correctly scoped to dev builds where a slower output
binary doesn't matter. Tiers 2/2′ are how you get the compile-time win on release
builds without paying the recursive tax. Tier 0 is a free prerequisite that is
currently missing.

---

## 2. Measured current state (self-host module, this machine)

Input: `build/compiler/build-kernel/bin/eco-compiler.mlir` (12.2 MB bytecode →
85,686 LLVM functions). Binary: `build/runtime/src/codegen/eco-boot-native`
(RelWithDebInfo, LLVM 21.1.8). Machine: 24 cores, 15 GB RAM. Measured with
`--lowering-stats` + `/usr/bin/time -v`.

### Full `-O2` executable (default, split-emit on)

```
Total pipeline                                          86.5 s   (CPU 180%, RSS 3.6 GB)
  LLVM backend (RS4GC + opt + object emission)          66.75 s  77.1%
  MLIR lowering pipeline                                11.01 s  12.7%
  MLIR -> LLVM IR translation                            6.02 s   7.0%
  Link (clang++ driver)                                  1.46 s   1.7%
  MLIR parse + verify                                    0.77 s   0.9%
  Internalize + GlobalDCE                                0.50 s   0.6%
```

### Decomposing the 66.75 s LLVM backend (via `--emit=llvm -O 2`, which times opt separately)

```
  RS4GC pipeline                       ~4.8 s     (per-function; cheap)
  -O2 optimization pipeline           ~51.3 s     <-- SERIAL, whole-module, 107% CPU
  Object emission (ISel/MC)           ~10.6 s     <-- ALREADY PARALLEL (SplitModule)
```

The opt-only run (`--emit=llvm -O 2`) clocked **107 % CPU — essentially one
thread**. That 51 s is the prize.

### `-O0` vs `-O2` IR (both `--emit=llvm`, non-internalized)

```
  -O0 IR: 352 MB, 85,686 defines,  emit=llvm total 26.0 s
  -O2 IR: 300 MB, 85,686 defines,  emit=llvm total 77.3 s   (delta ≈ 51 s = the opt pipeline)
```

**A tempting "double win" is refuted by this measurement.** One might expect
disabling the inliner to shrink the IR (less callee duplication) and thereby speed
up *codegen* too. But `-O2` IR is *smaller* than `-O0` (300 vs 352 MB) with an
*identical* define count: in the emit path the inliner copies bodies but can't
delete the externally-visible originals, and scalar cleanup nets out smaller. So
"disable inlining → smaller IR → faster codegen" is **not** supported by the data.
(The internalized executable path — where inline-then-GlobalDCE *can* delete
callees — may differ, but that was not measured and should not be assumed.) The
well-grounded win is **parallelizing the 51 s opt**, not shrinking IR.

---

## 3. How the pipeline is wired today (the facts the idea has to respect)

`runEcoBackend` (`runtime/src/codegen/EcoBackend.cpp:277`), `EmitObjectFile` case:

1. `internalizeAndDCEForExecutable(m)` (called by the driver at
   `eco-boot.cpp:732`) marks **everything except `eco_main` and
   `__eco_init_globals` internal**, then GlobalDCE. This runs *before* the backend
   and exposes the entire Elm call graph to IPO. (`EcoBackend.cpp:254-275`.)
2. `runRS4GCAndMaybeFramePointers(m)` — whole-module RS4GC, per-function statepoint
   insertion + `frame-pointer=all` per function. (`EcoBackend.cpp:220-252, 290`.)
3. `makeOptimizingTransformer(optLevel, 0, tm)` — the **standard LLVM per-module
   `-O2` pipeline (with the CGSCC inliner and all IPO)**, run **whole-module, single
   thread**. (`EcoBackend.cpp:300-304`.)
4. `emitObjectFilesSplit(m, N, paths, optLevel)` — `SplitModule` into N parts;
   each part round-trips through bitcode into its own `LLVMContext` + `TargetMachine`
   and is emitted on its own thread. **Emission only** — `emitObjectFile`
   (`EcoBackend.cpp:55-72`) uses `addPassesToEmitFile` (ISel/MC), *no* middle-end.
   (`EcoBackend.cpp:93-179, 310-312`.)

**Consequence (this corrects a plausible-but-wrong intuition):** because the split
in step 4 runs *after* the whole-module opt in step 3 and is codegen-only, **the
shipped split forfeits zero inlining/IPO** — it is verified byte-identical N=1 vs
N=8. So the produced compiler binary is built with **100 % whole-module IPO
today.** The idea's implicit assumption that "splitting already loses IPO, so
disabling it costs little more" is false for the current pipeline. The trade is
real and large.

Two distinct, easily-conflated architectures:

- **B2 (shipped):** parallel object *emission*, post-opt → **no** quality loss.
- **B2b (not shipped, = this idea):** per-partition *opt* / split-*before*-opt →
  **does** lose cross-partition IPO. Deferred earlier precisely "because it is the
  compiler."

---

## 4. Would disabling IPO actually cost produced-binary performance? (yes)

The counter-argument is "the Elm frontend already inlines, so LLVM IPO is
redundant." **It is not**, on inspection:

- The frontend inliner (`Compiler.GlobalOpt.MonoInlineSimplify`) runs at Mono-IR
  level with a **cost threshold of 10** (`Compiler/Eco/Config.elm:74`) and
  explicitly *before* closure/PAP lowering ("runs after monomorphization and before
  MLIR generation … before it becomes ECO closures/PAPs"). So it does only
  small-callee, first-order inlining and **cannot touch** the closure-apply / PAP /
  field-access / RC runtime glue that `EcoToLLVMClosures.cpp` emits later. That glue
  is exactly what the LLVM inliner cleans up.
- The genuine, large LLVM win is **folding ordinary first-order direct calls in the
  monomorphized call graph** — of which there are ~85 k functions with a low
  frontend inline budget, leaving plenty for LLVM.
- **"Disable all IPO" is broader than "disable the inliner."** The `-O2` pipeline
  also runs IPSCCP, GlobalOpt, called-value-propagation, DeadArgElim /
  ArgumentPromotion, GlobalDCE. **IPSCCP and GlobalOpt are actively valuable on a
  monomorphized program** — monomorphization produces many now-constant
  specializations for them to propagate. Turning IPO fully off discards this.
- One nuance that trims the win: eco's boxed-primitive allocators
  (`eco_alloc_int/float/char`) are **opaque external** decls
  (`EcoToLLVMFunc.cpp:87`), so module-`-O2` cannot see through them to elide GC
  allocations regardless of inlining — only true LTO could. So the "inlining
  unblocks SROA of transient boxes" benefit is smaller than one might guess; the
  real benefit is call-folding, not box elision.

Because the output binary is the compiler, a quality regression here compounds:
every subsequent `eco make` and every self-host stage runs on the slower binary.

---

## 5. GC safety of splitting before opt (verified: safe)

Running the `-O2` pipeline **per partition, after a whole-module RS4GC** is
GC-correct — adversarially checked against `design_docs/invariants.csv` and the
runtime:

- **RS4GC is intra-procedural.** `addEcoGCPipeline` runs per-function cleanup via
  `createModuleToFunctionPassAdaptor` then `RewriteStatepointsForGC`
  (`Passes/EcoPtrIntVerify.cpp:448-476`); statepoint/relocate insertion needs no
  cross-function context. The `eco-gc` GC name is a per-function attribute
  (`EcoToLLVM.cpp:363-366`) that survives the bitcode round-trip into each partition.
  The `EcoGCStrategy` registration is process-global (`EcoGCStrategy.cpp:33-42`) —
  fine across threads. RS4GC is run whole-module today purely as phase ordering,
  **not** a correctness requirement.
- **Statepoints are already stamped before opt in the proposed order**, so
  optimization is intra-procedural w.r.t. GC and needs no cross-function view to
  preserve roots. The **REP_LLVM_001(a)** hazard (no `i64` from `ptrtoint ptr<1>`
  live across a `gc.statepoint`) is the very reason RS4GC runs *before* opt today;
  splitting the *opt* stage does not change that ordering, so it is neither more nor
  less exposed. Disabling inlining/IPO **reduces** cross-statepoint code motion, so
  it is **neutral-to-safer** for GC, never less safe.
- **Frame pointers** are added per-function before the split (`EcoBackend.cpp:246-251`)
  and preserved through bitcode.
- **GC-root globals** (`eco.global` cells, `__eco_type_graph`) stay single-defined
  because `SplitModule` is called with `PreserveLocals=false`, which *externalizes*
  cross-partition locals to one definition rather than duplicating them
  (`EcoBackend.cpp:80-84, 113`). `__eco_init_globals` is force-preserved. These are
  long-lived `RootSet` roots (HEAP_020), disjoint from stackmap roots, so they don't
  depend on which partition holds a function.
- **Stackmaps already scale to many partitions.** `StackMap::parse`
  (`runtime/src/allocator/StackMap.cpp:120-290`) has an outer multi-blob loop,
  builds a blob-local function table per blob, and keys records by **absolute return
  address** (`funcAddr + instructionOffset`) — never by function id or patchpoint id
  — so N concatenated blobs never collide. No size caps. One-function-per-module
  (~85 k blobs) is *functionally* fine (only ~40 B section overhead per blob); it's
  the *codegen* overhead, not the stackmap, that rules that granularity out.

The separate `--rs4gc-after-opt` experimental flag (run RS4GC *after* opt on
abstract `ptr<1>`) is a **different, riskier axis** and is orthogonal to this idea —
don't couple them.

---

## 6. `SplitModule` internals, and answers to the four design questions

The following is verified against the actual LLVM 21.1.8 source
(`llvm/lib/Transforms/Utils/SplitModule.cpp`, `CloneModule.cpp`,
`Passes/PassBuilderPipelines.cpp`, `Transforms/IPO/FunctionImport.cpp`) and the
rustc partitioning source, not from memory.

### 6.1 What the `SplitModule` scaffolding is and does (Q1)

`llvm::SplitModule(M, N, callback, PreserveLocals, RoundRobin)` (309 lines,
`SplitModule.cpp`) mechanically cuts **one** `llvm::Module` into N sub-modules and
hands each to a callback. eco wraps it (`emitObjectFilesSplit`, `EcoBackend.cpp:93-179`)
with: serialize each partition to bitcode on the parent thread → re-parse into a
**fresh `LLVMContext`** per worker thread → **fresh `TargetMachine`** per thread →
emit one `.o` each in parallel → link (the linker concatenates `.text`/`.data` and
the N `.llvm_stackmaps` blobs; `StackMap::parse` reads all blobs).

Internally, under eco's `PreserveLocals=false`:

1. **`externalize()` every local GV first** (`SplitModule.cpp:205-215, 242-251`):
   internal/private linkage → `ExternalLinkage` + `HiddenVisibility`; unnamed
   entities get the name `__llvmsplit_unnamed`. This is so a definition landing in
   one partition stays linkable from its siblings.
2. **`findPartitions`** builds a union-find whose *only* call-graph-ish edge is
   "union a **local-linkage** GV with its users" (`:158-159`), plus
   comdats/aliases/ifuncs/blockaddresses. **But step 1 already stripped all local
   linkage**, so that branch never fires → **zero call-graph clustering**.
3. Nearly every function is therefore assigned by **`isInPartition` = low-16-bits of
   `MD5(name) % N`** (`:235`) — a pure name hash: **N-dependent, deterministic, and
   oblivious to both code size and the call graph.** Any cluster that does form is
   balanced by **GV *count*, not instruction count** (`:166-202`).
4. Each partition is produced by `CloneModule` with a per-GV predicate; a GV **not**
   in this partition is cloned as a **bodyless external `declare`**
   (`CloneModule.cpp:142-148` for functions). So a call to an out-of-partition callee
   resolves to a declaration the partition's optimizer **cannot inline**.

The function's own comment states the goal is purely *"no locals need to be
globalized"* (`:110-113`) — **not** preserving inlining. This is exactly why eco runs
whole-module `-O2` **before** the split: post-opt, the split is codegen-only and
loses nothing; a split *before* opt would sever inlining across arbitrary
hash-determined cuts.

### 6.2 Can we parallelize codegen without disabling IPO? (Q2) — depends which stage

- **Object emission / ISel / MC — yes, already, zero IPO loss.** Codegen is strictly
  per-function; there is no interprocedural optimization there to lose. Splitting the
  already-optimized module and emitting N objects in parallel is the shipped state.
- **The opt stage (the ~51 s bottleneck) — this is where a naïve split loses IPO**,
  because the cross-function inlining lives here. There are three ways to parallelize
  it, and only some keep IPO. Ranked by payoff/effort for eco:

  1. **ThinLTO (full IPO preserved, fully parallel) — the proper answer.** Split
     before opt, but emit a per-partition **`ModuleSummaryIndex`**, merge into a
     combined index, compute per-partition **import lists**
     (`llvm::ComputeCrossModuleImport`), and have each partition **import** the
     selected hot/small callee bodies as `available_externally` before running its
     own `-O2` in parallel; `EliminateAvailableExternally` + `GlobalDCE` drop the
     copies so no duplicate object code is emitted. The importer's
     **size(default 100 instrs) + hotness(Hot ×10, Critical ×100, Cold ×0)** heuristic
     (`FunctionImport.cpp:79-114, 318-334`) reconstructs cross-module inlining;
     `alwaysinline` callees are force-imported. **eco already has most of the backend
     plumbing** (SplitModule, bitcode round-trip, per-thread context+TM); what's
     missing is summaries + combined index + `FunctionImporter::importFunctions`.
     Reusing LLVM's `LTO`/`ThinLTOCodeGenerator` API avoids hand-rolling. This is
     precisely what **rustc uses on its own self-hosting compiler** ("thin local LTO").
  2. **Codegen-units + replication (rustc's manual model).** Same family as (1) but
     you replicate the hot/small glue yourself at partition time (see §6.4). A
     "poor-man's" version — mark hot cross-partition helpers `alwaysinline`,
     physically copy their bodies into every referencing partition as
     `available_externally`, then per-partition `-O2` — captures ~80 % and is a good
     way to **measure** the win before committing to the full index.
  3. **Split *after* the whole-module inliner; parallelize only the intra-procedural
     tail — low effort, low ceiling, zero IPO loss.** Run module-simplification + the
     CGSCC inliner whole-module (serial, keeps all inlining), then split and run only
     the post-inline vectorizer/cleanup tail per partition. **Caveat (important):** the
     CGSCC inliner *fuses* the per-function simplification inside itself (§6.3), and
     that fused part is the bulk of opt time — the parallelizable tail is only the
     post-inline `buildModuleOptimizationPipeline` (**inferred** ~20-35 % of opt), so
     the ceiling is only ~1.3-1.5× on the opt stage. Cheap insurance, not the headline.

### 6.3 Partial IPO: what to disable vs keep (Q3)

**Disable exactly one pass: the CGSCC `InlinerPass`** (`PassBuilderPipelines.cpp:1279`,
run via the CGSCC adaptor). It is both the expensive pass *and* the parallelism
blocker, for two reasons: (i) it needs whole-module visibility (it inlines callee
bodies into callers, which only works when both share a module); (ii) it **fuses the
entire per-function simplification pipeline inside itself** —
`buildFunctionSimplificationPipeline` is nested via `createCGSCCToFunctionPassAdaptor`
(`:989-991`) and re-run bottom-up per SCC, so the inliner is where **most of the O2
wall-clock goes**. Dropping it means re-adding a plain
`buildFunctionSimplificationPipeline` wrapped in `createModuleToFunctionPassAdaptor`
(no inlining), which runs fine per-partition in parallel.

**Keep (cheap, high-value whole-module IPO — run once, serially, before the split):**

- **IPSCCP** — interprocedural constant/range propagation. **Disproportionately
  valuable on monomorphized code**, where a specialization is often called with
  statically-known constant arguments it can fold.
- **GlobalOpt** — internalizes/simplifies globals, evaluates static initializers,
  deletes dead globals. Cheap module-local rewrite.
- **GlobalDCE** — removes whole-module-unreachable functions/globals. Critical *after*
  monomorphization (which emits many globally-dead specializations); doing it once
  before the split shrinks every partition's input. (eco already runs a GlobalDCE in
  `internalizeAndDCEForExecutable`.)
- **function-attrs** (`PostOrderFunctionAttrsPass` + `ReversePostOrderFunctionAttrsPass`)
  — infers `readnone/readonly/nounwind/willreturn/norecurse/nocapture` from the call
  graph. Cheap, and unlocks both downstream per-function opt and better ISel;
  especially valuable on monomorphized pure-Elm code full of provably-pure helpers.

The partition is principled: these four are O(module) analyses or cheap rewrites —
**not** the bottleneck — and they capture the cross-module *facts* (constants, purity,
dead-code). Run them whole-module once (fast), then split and parallelize the
expensive-but-per-function simplification + vectorizer tail. The one thing you *lose*
by dropping the inliner is call-folding — which for eco is concentrated in first-order
direct calls across the ~85 k monomorphized Elm functions (the closure/PAP/alloc glue
is external runtime calls, un-inlinable by module-opt regardless; see §4).

### 6.4 The correct unit of work (Q4) — not one function per module

One-function-per-module is wrong for two independent reasons: LLVM optimizes only
*within* a module, so maximal granularity "would effectively prohibit inlining and
other inter-procedure optimizations" (rustc `partitioning.rs:29-38`); and tiny units
pay fixed per-module overhead (context setup, re-analysis, duplicated
`available_externally` bodies) — hence rustc's hard **`NON_INCR_MIN_CGU_SIZE = 1800`**
floor. There are two correct units, one per tier:

- **IPO-off dev tier:** the unit does **not** affect code quality (no IPO to lose), so
  each function is optimized in isolation → **machine code is independent of N**
  (a reproducibility win). Choose **N ≈ cores**, **cost-balanced by instruction
  count** (greedy: sort functions largest-first, assign to the least-loaded of N
  bins). **Stock `SplitModule` does *not* do this** — it balances clusters by GV count
  and sends everything else through the MD5 name hash, which ignores code size and can
  strand the heavy functions on one thread. For the dev tier the hash cut is
  acceptable, but eco may want a cheap size-cost balancer to avoid a straggler.
  Going beyond N ≈ cores only adds overhead.
- **Keep-IPO release tier:** the unit is rustc's **codegen unit** — call-graph-aware
  clusters that keep caller+callee and (mandatorily) whole **SCCs** together, sized to
  N ≈ cores, **plus replicated `alwaysinline` glue**. rustc realizes this exactly:
  place items per source module (call-graph locality), **merge** down to N picking the
  source unit with greatest *inlined-item overlap* ("minimize duplication of inlined
  items"), and physically insert a CGU-private **internal-linkage copy** of every
  reachable `#[inline]`/`LocalCopy` callee into each referencing unit
  (`InstantiationMode::LocalCopy`, `mono.rs:29-50`; `partitioning.rs:262-405`). The
  ThinLTO equivalent does the same replication as `available_externally` imports.

  **Minimizing IPO loss for fixed N is a graph min-cut objective:** every call edge cut
  across a partition boundary is a permanently lost inline (the callee becomes a
  bodyless extern). SCC/call-graph clustering minimizes those cuts.

**Correction to an earlier idea in this doc's history:** marking the glue
`linkonce_odr`/`available_externally` and hoping `SplitModule` replicates it does
**not** work — `SplitModule` clones out-of-partition GVs as *declarations*, so a body
lands in exactly one partition. Replication must be done **by eco** (physically copy
the body into each referencing partition, as rustc does) or via **ThinLTO's
importer**. `available_externally` is the right linkage for the copies (inlinable,
never emitted, discardable); plain `linkonce` is *not* inlinable.

### 6.5 The right N and scaling

- **Per-partition overhead:** bitcode serialize + parse + fresh context + `TargetMachine`
  per partition. Fine at N ≈ 16; prohibitive at N = 85,686. **Sweet spot N ≈
  min(cores, 16–24)**, matching the existing `--split-codegen` heuristic
  (`eco-boot.cpp:751-763`).
- **Scaling is sublinear** — the shipped emission split reaches only ~180 % CPU on 24
  cores (memory-bandwidth bound: 300 MB IR, 3.6 GB RSS). Expect parallel opt to land
  ~6–10× effective, not 16×.

---

## 7. Compile-time estimate

> **Measured 2026-07-06 (implemented — `plans/parallel-llvm-opt-partitioning.md`,
> `backendstats-runs.txt`).** Self-host mlir → native exe, `-O 2`, 24 cores:
>
> | mode | LLVM backend | total wall | CPU |
> |---|---|---|---|
> | default (whole-module -O2) | 65.8 s | 86.5 s | 180% |
> | `--parallel-opt=dev` | **28.7 s** | **49.0 s** | 281% |
> | `--parallel-opt=cgu` | **31.4 s** | **53.4 s** | 303% |
>
> Backend **2.1–2.3×**, total **1.6–1.8×**. The ~51 s serial opt is gone (cheap
> IPO prologue + per-partition opt on the emission threads). This confirms the
> §6.3 premise: dropping the fused CGSCC inliner + parallelizing recovered ~37 s,
> so it *was* the bulk. **Produced-binary runtime-quality measured (clean self-host
> self-compile): cgu −0.5% (≈0, passes the ≤3% gate), dev +1.7%** — see
> `plans/parallel-llvm-opt-partitioning.md` / `backendstats-runs.txt`. The estimate below predicted ~40–45 s; the extra
> few seconds is the MLIR-lowering + translation floor (~17 s) now dominating.

Parallelizing opt at N≈16 (Tier 2/2′), keeping emission parallel and fusing
opt+emit into one per-partition pass (opt then emit on the same thread, no re-split):

```
  lowering 11 + translate 6 + RS4GC 4.8 + opt ~8-12 (was 51) + emit ~10 + link 1.5
  ≈ 40-45 s   (from 86.5 s)  — roughly a further ~2x
```

Tier 1 (dev, no-inline function pipeline) would additionally cut per-partition opt
cost (no inliner, cheaper pipeline), plausibly landing the backend in the ~25–30 s
range — but on a slower output binary. These are estimates; the opt-parallel factor
and the no-inline speedup should be measured on a prototype (see §9).

**Which lever actually parallelizes the bulk.** The ~51 s is dominated by the CGSCC
inliner + its *fused* per-function simplification (§6.3), so:
- **Tier 1 (IPO off)** parallelizes ~all of it (the fused simplification becomes a
  plain per-function pipeline across N threads) — biggest compile-time win, largest
  quality hit.
- **Tier 2 (ThinLTO)** also parallelizes the bulk (each partition inlines locally over
  imported bodies), but adds import + re-optimization of imported bodies per partition,
  so its opt wall-clock is somewhat higher than Tier 1's and its output quality much
  higher.
- The **"reorder and parallelize only the post-inline tail"** option (§6.2 option 3)
  leaves the inliner+fused-simplification serial, so its ceiling is only ~1.3-1.5× on
  the opt stage (**inferred** ~20-35 % tail) — cheap insurance, not the headline.

---

## 8. Implementation sketch

The parallel-opt change is **small** because the split scaffolding already exists.

**Tier 0 (free, do first): move the split *policy* into the shared backend — don't
duplicate it.** `EcoNativeDriver.cpp` (the unified `eco` path used by users *and*
self-host stages 6–9) never sets `job.numPartitions`, so it always emits
single-threaded (`EcoNativeDriver.cpp:247-257`). The naïve fix is to copy the
~40-line split-setup block from `eco-boot.cpp:744-800`. **Don't** — that re-forks
logic the pipeline-unification work deliberately consolidated. See §8.1 for the
placement. This gives the *already-shipped, quality-neutral* ~85 s→~10.6 s emission
win to production builds with **no** IPO trade, and is a prerequisite for everything
below.

### 8.1 Placement: the split policy belongs in the shared `EcoBackend`, not in a driver

The backends were unified so that all of `eco-boot`, the native `eco`
(`EcoNativeDriver`), `ecoc`, and the JIT funnel their LLVM work through **one**
choke point — `eco::runEcoBackend(Module&, EcoBackendJob&)` in `EcoBackend.cpp:277`
(callers: `eco-boot.cpp:801`, `EcoNativeDriver.cpp:258`, `ecoc.cpp:248` &`:292`).
Of the four things the split needs, **three are already shared**:

- the **split mechanism** — `emitObjectFilesSplit` lives inside `runEcoBackend`
  (`EcoBackend.cpp:93-179`);
- **linking** — both drivers call the single `eco::linkExecutable`
  (defined once in `EcoNativeDriver.cpp:669/677`, both a `string` and a
  `vector<string>` overload; `eco-boot.cpp:402-418` are thin wrappers over it);
- temp-file creation is platform-neutral (`llvm::sys::fs::createTemporaryFile`).

**Only the *policy* is stranded in a driver.** The partition-count decision
(count defined fns → gate `≥4000` → auto `= min(cores,16)`, `bySize = fns/2000`)
and the temp-`.o` bookkeeping sit inline in `eco-boot.cpp:744-800`. The knob itself,
`--split-codegen`, is a `cl::opt` **only in `eco-boot.cpp:170`** — it is *not* on
`EcoNativeOptions`, so the unified driver has no way to even request it. The shared
`EcoBackendJob` exposes only the *raw* result of the policy (`numPartitions` +
caller-pre-created `objectFilePaths`, `EcoBackend.h:142-143`), which forces each
driver to re-derive it.

**Refactor (this is Tier 0):**

1. Replace the raw `EcoBackendJob::numPartitions` with a *request* +
   *eligibility*: `unsigned splitCodegen = 0` (0 = auto, 1 = off, N = explicit —
   same semantics as the flag) and `bool splitEligible` (the driver's
   `isExecutable && !emitObjOnly && !sharedLib` — it already computes this for the
   `internalizeAndDCEForExecutable` gate). These are pure *inputs* to a shared
   decision, so they belong on the shared job.
2. Move the decision into a shared helper, e.g. `unsigned
   choosePartitionCount(const Module&, unsigned request, bool eligible)` in
   `EcoBackend.cpp`, called from `runEcoBackend`'s `EmitObjectFile` case. It has
   everything it needs — the module (function count) and core count.
3. Let `runEcoBackend` **own the part-file lifecycle**: mint the N temp `.o`s
   itself and return them (add a `std::vector<std::string>& producedObjects`
   out-param, or return them in a small result struct), so the caller links
   whatever it gets back and deletes them. This removes the `objectFilePaths`
   pre-population from every driver.
4. Each driver collapses to: set `job.splitCodegen` (from its own flag/option) and
   `job.splitEligible`, call `runEcoBackend`, then `eco::linkExecutable(produced,
   …)` (the already-shared vector overload) and clean up.

Result: the ~40 lines exist **once**, in the layer that already owns the mechanism
and the link; `eco make`, `eco-boot`, and any future backend get parallel emission
for free; and adding a `--split-codegen` (or config) knob to `EcoNativeOptions`
becomes a one-line plumb rather than a re-implementation. The JIT path
(`JITInvokePacked`) is unaffected — it emits no objects, so `choosePartitionCount`
is only reached in the `EmitObjectFile` branch. **The same shared seam is where the
Tier 1/2 parallel-*opt* step plugs in** (the per-partition opt call goes inside
`emitObjectFilesSplit`'s worker lambda), so doing Tier 0 as a shared-layer refactor
is also what makes Tiers 1/2 a localized change rather than a per-driver one.

**Tier 1/2′ (parallel opt): move opt into the per-partition thread.**
In `emitObjectFilesSplit` (`EcoBackend.cpp:93-179`), the per-thread lambda already
does `parseBitcodeFile` → `createEcoTargetMachine` → `emitObjectFile`. Insert an opt
step between parse and emit, and skip the whole-module opt in `runEcoBackend`:

```cpp
// inside the per-partition lambda, after parseBitcodeFile (:131), before emit:
if (optLevel != CodeGenOptLevel::None) {
    auto optPipeline = /* Tier 2': */ mlir::makeOptimizingTransformer(level, 0, tm.get());
                       /* Tier 1 : a custom no-inline PassBuilder pipeline (see below) */
    if (auto e = optPipeline(mod.get())) { errs[i] = ...; return; }
}
```

and in `runEcoBackend`, gate out the whole-module `makeOptimizingTransformer`
(`:300-304`) when `numPartitions > 1`.

- **Tier 2′ (codegen-units)** needs *no new pipeline code* — it reuses
  `makeOptimizingTransformer` per partition. Keeps intra-partition IPO; loses
  cross-partition. This is rustc's `-Ccodegen-units=N, lto=off` model.
- **Tier 1 (disable IPO)** needs a **custom `PassBuilder` pipeline**:
  `makeOptimizingTransformer` has no IPO toggle. Build
  `PB.buildFunctionSimplificationPipeline(...)` wrapped in
  `createModuleToFunctionPassAdaptor` (optionally + an always-inliner +
  GlobalDCE), i.e. a function-only pipeline. This is the ~30-line piece of new code.

**Recovering IPO quality under splitting (for Tier 2′):** mark the hot runtime glue
`alwaysinline` at lowering (`EcoToLLVMClosures.cpp` etc.) *and* replicate those small
functions into every partition (a `linkonce_odr` / available-externally import), so
the always-inliner can fire even across the hash-based partition boundary. This is a
poor man's ThinLTO import and claws back most of the glue-inlining loss.

**Tier 2 (ThinLTO)** is the principled endpoint: emit per-partition summaries, let
the ThinLTO backend import hot/small callees across partitions, then parallel
opt+codegen. Highest lift, best quality-vs-parallelism, and it is the standard
answer to exactly this tension.

---

## 9. Risks & what to measure before committing

1. **Produced-binary regression (the big one).** Build the self-host compiler two
   ways (whole-module IPO vs Tier-1 no-IPO vs Tier-2′ codegen-units), then time each
   *as a compiler* on a fixed workload (e.g. lower `eco-compiler.mlir`). This
   directly quantifies the recursive tax. Do this before defaulting any release
   build to split-opt.
2. **Parallel-opt scaling.** Prototype Tier 2′ and measure the actual opt wall-clock
   and CPU% at N=8/16/24 — confirm the 51 s → ~8-12 s estimate and where memory
   bandwidth caps it.
3. **The no-inline speedup and IR-size effect** in the *internalized exe* path
   (unmeasured here; the emit-path measurement refuted the naive version).
4. **Determinism/GC regression tests** already exist for the emission split (N=1 vs
   N=8 byte-identical; forced-2-way ADT/GC AOT sweep) — extend them to the
   parallel-opt path. Tier 1's N-independence makes byte-identical checks *easier*;
   Tier 2′'s N-dependence means compare *behavior*, not bytes.
5. **Don't conflate with `--rs4gc-after-opt`** — keep that GC-critical flag on its
   own validation track.
6. **Confirm the pass-list mapping.** Verify `mlir::makeOptimizingTransformer` really
   drives LLVM's `buildPerModuleDefaultPipeline(O2)` so the §6.3 KEEP/DISABLE split
   (drop the CGSCC inliner, keep IPSCCP/GlobalOpt/GlobalDCE/function-attrs) maps
   cleanly onto a custom `PassBuilder` pipeline. If it uses a bespoke pipeline, port
   the split accordingly.
7. **Load-balance the dev tier.** Stock `SplitModule` balances by GV *count* / MD5
   hash, not code size (§6.1/§6.4), so one worker can get all the heavy functions.
   Measure per-partition opt-time skew at N ≈ cores; if a straggler dominates, add a
   cheap instruction-count balancer (sort largest-first, greedy least-loaded bin)
   rather than relying on the hash.

## 10. Bottom line

- The user correctly identified the remaining serial bottleneck: **~51 s of
  whole-module `-O2` opt, ~59 % of the backend, single-threaded.**
- Making it parallel via `SplitModule` is **GC-safe and cheap to implement** (the
  scaffolding exists; ~15–45 lines).
- **But "disable all IPO / one module per function" as stated is the wrong default
  for release builds**: it trades a currently-realized 100 % whole-module IPO for
  ~1/N, and the output binary is the compiler. It also over-reaches by discarding
  IPSCCP/GlobalOpt, which help monomorphized code.
- **The idea is exactly right for a dev/fast tier** (throwaway builds), and the
  release path should get its parallelism from **codegen-units-with-alwaysinline-glue
  or ThinLTO**, which parallelize opt while keeping most IPO.
- **Free first step, missing today:** the already-shipped emission split reaches
  only `eco-boot`, not the production `eco make` path. Fix it *in the shared
  `EcoBackend` layer* (hoist the partition-count policy + temp-file lifecycle into
  `runEcoBackend`; §8.1), not by duplicating `eco-boot`'s block — the mechanism and
  the linker are already shared, only the policy is stranded in the driver. This is
  also the seam the Tier 1/2 parallel-opt step plugs into.
