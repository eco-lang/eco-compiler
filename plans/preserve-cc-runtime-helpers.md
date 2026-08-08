# preserve_most/preserve_all calling conventions on GC runtime helpers

**Run L addendum (2026-08-08, benchmarks/tier2-opt.md): the return-safe
variant — residual ideas (a)+(c) below, `no_caller_saved_registers` on a
CALL-FREE `eco_bump_state` — was BUILT, VERIFIED, and MEASURED FLAT
(interleaved pairs −0.63 %/+0.27 %, majors ≡, out.mlir byte-identical),
so the NCSR flag + backend fixup were REVERTED per house pattern. KEPT
standalone: the call-free body (inline TLS read, 6 instructions) and
`constinit` + `tls_model("initial-exec")` on `Allocator::tl_heap_` — both
strict improvements. Two further toolchain landmines documented for
posterity: (1) cross-TU access to an extern C++ `thread_local` emits a
TLS-dynamic-init guard (`_ZTH` wrapper + conditional call) unless the
variable is `constinit`; (2) `-fPIC`-without-`-fPIE` compiles (the
EcoRuntimeStatic archive Stage 5 links!) use general-dynamic TLS = a
`__tls_get_addr` call whose register-save cost is baked in at COMPILE time
even though the linker relaxes the call away — verify the LINKED binary,
never a hand-compiled .o from a differently-flagged target. The caller-
side mechanism is real (74,659 retagged sites = text −0.78 %) but wall-
neutral on the int-heavy compiler workload; xmm relief untested — a
float-heavy user workload could revisit via the same recipe. This closes
the calling-convention arc; the remaining register lever is
plans/gc-free-function-propagation.md (statepoint reduction + leaf FP
omission).**

**Status: BUILT + MEASURED 2026-08-08 — FATAL NO-GO on x86-64, fully
REVERTED. Both experiment arms SIGSEGV at 0.09 s (benchmarks/tier2-opt.md
Run K). Root cause, asm-verified on clang/LLVM 21.1.8: the x86-64
callee-saved sets for preserve_most/preserve_all (CSR_64_RT_MostRegs /
CSR_64_RT_AllRegs) INCLUDE RAX — a value-returning callee's epilogue ends
`pop %rax; ret`, restoring the caller's pre-call RAX over the return value.
The conventions cannot carry a return value on x86-64 (AArch64 excludes
X0–X8, so LangRef's "only R11" note is target-specific, not general).
§1.3's "attribute-on-definition + ccc caller is safe" is therefore WRONG
for value-returning functions — annotating the C++ definitions alone
already corrupts kernel-side callers (`eco_scratch_mark`'s returned mark).
Every primary target returns a value (`eco_bump_state`,
`eco_follow_forward`, `eco_list_head_hybrid`, `eco_scratch_mark`,
`eco_alloc_inline_slow`, `eco_list_tail_hybrid`) ⇒ Steps 1 AND 2 are
unimplementable as designed. DO NOT RE-ATTEMPT with these conventions on
x86-64.**

**Secondary autopsy finding (kills the fallback variants too):** the
compiled helper bodies are not "tiny" — `eco_bump_state` makes a
non-inlined call to `Allocator::bumpState()` (defined in Allocator.cpp,
invisible to RuntimeExports.cpp), so under preserve_all it saved 8 GPRs +
all 16 xmm per call; `eco_scratch_push_boxed` (per-element in cons loops)
saved 14 GPRs per call under preserve_most. Any callee with a non-inlined
inner ccc call must save every caller-saved register it transitively
clobbers, so the "callee touches almost nothing ⇒ free" premise fails for
exactly the hot helpers. Residual ideas, all requiring new plans and A/B
evidence: (a) `__attribute__((no_caller_saved_registers))` (x86-specific;
excludes arg/return regs, so returns work) — but the inner-call save cost
above applies in full, xmm included; (b) void-returning subset only
(`eco_scratch_push_*`, `eco_scratch_abandon`) — same inner-call caveat,
scratch pushes are hot; (c) make `eco_bump_state` call-free first
(inline-visible bump state or TLS-direct, §2.6) — the prerequisite for ANY
convention/attribute variant to be worth measuring. One data point in
favour of the caller-side mechanism being real: retagging 223,286 call
sites shrank text by 2.16 MB (−3.8%) — the win exists, but only a
return-safe, cheap-callee mechanism can collect it.

**Status (original): PLANNED (2026-08-07). Anchors verified against HEAD on
2026-08-07; re-grep before editing (treat all line numbers as "near
here").**

Two-step experiment. Step 1: `preserve_all` on `eco_bump_state` +
`preserve_most` on the tiny gc-leaf helpers, measured via the interleaved A/B
protocol. Step 2 (gated on a Step-1 win): the statepointed slow calls
(`eco_alloc_inline_slow`, `eco_list_tail_hybrid`).

**Why (the mechanism, honestly sized):**

- Under `ccc` on x86-64 SysV, every call clobbers 9 GPRs (rax, rdi, rsi, rdx,
  rcx, r8–r11) and **all 16 xmm registers**. Only rbx, rbp, r12–r15 survive.
  Any value live across a call must occupy one of those 6 callee-saved GPRs
  (paid for by prologue/epilogue pushes that run on the *hot* path of the
  containing function) or be spilled/split around the call. Any unboxed
  `f64` live across any call is spilled unconditionally — zero xmm registers
  are callee-saved.
- Every generated function and call in Eco is `ccc` today: no `CConv`
  attribute is ever set (`EcoToLLVMFunc.cpp:83/:145` create `LLVMFuncOp`s
  bare; repo-wide grep for `CallingConv|cconv|fastcc` has zero hits outside
  `build/`). For generated functions that uniformity is load-bearing
  (closure/kernel function-pointer ABI) and is **out of scope here** — this
  plan touches only direct-call-only runtime helper symbols the backend
  itself declares.
- `preserve_most`/`preserve_all` pass arguments and return values **exactly
  like C** (LangRef); they only enlarge the callee-saved set. So from the
  caller's view the call clobbers (almost) nothing and hot-path values stay
  in ordinary caller-saved registers; the save/restore cost moves into the
  callee's prologue — the right trade for helpers that are tiny, cold, or
  once-per-nursery-block.
- **What this cannot buy:** relocation spills. `eco_alloc_inline_slow` runs a
  minor GC that MOVES nursery objects; live GC pointers across it are stale
  after the call, so RS4GC's statepoint spill/reload is a semantic
  requirement, not a register-save artifact. Step 2 helps only *non-GC* live
  values (i64/f64/i16/flags). Step 1's gc-leaf helpers have no statepoint at
  all, so there the full clobber-set win applies.
- **Caution prior:** E1.3 Run O showed call-overhead work can be wall-neutral
  on the GC-bound self-compile, and the tier pattern (×9) says static
  reasoning oversells. Expected outcome: low-single-digit wall win at best,
  plausibly neutral. The experiment is cheap (~a day), strictly bounded, and
  the A/B needs only ONE runtime build (see §2.3) — that is why it is worth
  running anyway. Precedent: JavaScriptCore and V8 use `preserve_most` on GC
  slow-path stubs and write barriers for exactly this mechanism.

---

## 1. Ground truth (2026-08-07, all code-read)

### 1.1 The helper roster

gc-leaf helpers declared at marker-expansion time in `EcoBackend.cpp`
(`addFnAttr("gc-leaf-function")` sites):

| Symbol | Declared at | Defined at | Shape |
|---|---|---|---|
| `eco_bump_state` | `EcoBackend.cpp:816` | `RuntimeExports.cpp:183` | returns thread-stable address; `memory(none)`, speculatable, CSE/LICM'd |
| `eco_follow_forward` | `EcoBackend.cpp:712` | `RuntimeExports.cpp:4580` | cold forwarding-chain resolve, tiny |
| `eco_list_head_hybrid` | `EcoBackend.cpp:948` (slowIsGcLeaf=true) | `RuntimeExports.cpp:4170` | chunk-aware head, small |
| `eco_scratch_mark` / `eco_scratch_push_boxed` / `eco_scratch_push_scalar` | `EcoBackend.cpp:1468` loop | `RuntimeExports.cpp:4250/4254/4260` | scratch-stack ops, small |

Statepointed (deliberately NOT gc-leaf — Step 2 targets):

| Symbol | Declared at | Defined at | Fire rate |
|---|---|---|---|
| `eco_alloc_inline_slow` | `EcoBackend.cpp:823` | `RuntimeExports.cpp:194` | once per nursery block (thousands of allocs) |
| `eco_list_tail_hybrid` | `EcoBackend.cpp:1178` (slowIsGcLeaf=false) | `RuntimeExports.cpp:4182` | cold |

**NOT in scope, do not touch:** the `__eco_*` marker symbols
(`__eco_resolve_fwd`, `__eco_slot_to_hptr`, `__eco_alloc_inline`, list-cursor
markers). They are declare-only and fully expanded/stripped before codegen
(REP_LLVM_002 relies on `__eco_slot_to_hptr` surviving *unmodified* until
StripEcoCastBarriers). A CC on a marker is at best meaningless and at worst
breaks the strip-pass pattern match.

There is also a large legacy `gcLeaf=true` declaration table in
`EcoToLLVMRuntime.cpp:267–524` (`eco_alloc_*_fast`, `eco_init_*_at`,
`eco_store_*`, …). Most of that emission was deleted by R5/HEAP_034; §2.1's
census decides whether any of it still appears often enough to annotate.

### 1.2 Call-site provenance (who must agree on the CC)

- **Generated code:** calls created inside the `EcoBackend.cpp` marker
  expansions (`expandInlineDerefs`, `expandInlineAllocs`,
  `expandListProjMarkers`, `expandGetTagMarkers`, `expandListCursorMarkers`)
  plus pre-existing `CallInst`s translated from MLIR (scratch helpers,
  emitted by `EcoListTemplate` via `EcoToLLVMRuntime`). A single LLVM-level
  fixup that walks each symbol's users covers both (§2.3).
- **Kernel C++:** `elm-kernel-cpp/src/json/JsonExports.cpp:662–669` calls
  `eco_scratch_mark`/`eco_scratch_abandon` directly. So the attribute MUST
  live on the declarations in `RuntimeExports.h` (`:96/:164/:715`), not just
  the definitions — clang then compiles kernel-side call sites with the
  matching convention automatically.
- **Runtime-internal C++ callers** get the same treatment via the same
  header.

### 1.3 The safety asymmetry that makes the A/B cheap

A callee compiled as `preserve_most`/`preserve_all` preserves a strict
superset of what a `ccc` caller assumes, and passes args/returns identically.
Therefore **attribute-on-definition + plain-ccc call site is safe** (merely
conservative), while call-site-CC + plain-ccc definition would be a silent
miscompile. Consequence: annotate the C++ side unconditionally; gate only the
generated-side CC behind `ECO_PRESERVE_CC`. One runtime build serves both A/B
legs; the env flag is the only difference between them.

### 1.4 Constraints and non-goals

- Generated functions stay `ccc` (closure/kernel pointer ABI uniformity).
  REP_001 / REP_ABI_001 are untouched: this plan changes no Elm-type↔ABI-slot
  mapping, only the preserved-register set of specific runtime symbols at the
  LLVM level.
- No `fastcc` (SysV ccc already passes 6 int + 8 fp args in registers — the
  passing set is not the lever), no `preserve_none`, no IPRA (helper
  definitions live in the separately compiled runtime lib, invisible to it).
- `preserve_most` does not preserve xmm or r11 on x86-64; `preserve_all` adds
  the vector registers. Both supported by clang 21 on x86-64 and AArch64
  (mac build unaffected but should be smoke-tested flag-on before any
  default-on there).
- CloneModule preserves both fn attrs and calling conventions, so the fixup
  composes with per-partition RS4GC/opt exactly like the existing gc-leaf
  declaration attrs (`EcoBackend.cpp:276` precedent).

---

## 2. Step 1 — the initial experiment

### 2.1 S1.0: census (half a day, decides the exact roster)

Dump one representative final module pre-emission (existing `--text-mlir` /
partition-dump paths, or a one-off `ECO_PRESERVE_CC_SCAN` print in the fixup
walk) and count, per §1.1 symbol: static call sites and whether it appears at
all. Also count surviving call sites of the legacy `EcoToLLVMRuntime` gcLeaf
table on a default-flag build. Anything with ~0 sites drops out of the
experiment; anything from the legacy table with substantial sites joins it.
No dynamic counters needed — this only sizes the roster.

### 2.2 S1.1: annotate the C++ side (unconditional)

In `RuntimeExports.h`, add

```c
#if defined(__clang__) && (defined(__x86_64__) || defined(__aarch64__))
#define ECO_PRESERVE_MOST __attribute__((preserve_most))
#define ECO_PRESERVE_ALL  __attribute__((preserve_all))
#else
#define ECO_PRESERVE_MOST
#define ECO_PRESERVE_ALL
#endif
```

and apply to both declaration and definition:

- `ECO_PRESERVE_ALL eco_bump_state` — body touches almost nothing, so the
  enlarged save set is free, and callers get "clobbers nothing but rax".
- `ECO_PRESERVE_MOST` on `eco_follow_forward`, `eco_list_head_hybrid`,
  `eco_scratch_mark`, `eco_scratch_push_boxed`, `eco_scratch_push_scalar`
  (+ `eco_scratch_abandon` for kernel-side consistency, + census additions).
  Note a preserve_most body that itself calls deeper `ccc` code (scratch
  growth path) simply saves/restores around that inner call — cost lands on
  the helper's own slow path, which is the point.

Guard rails: all of these are non-variadic and nounwind (preserve CCs are not
exception-safe — fine here). If the mac/AArch64 build turns up a toolchain
gap, the macro collapses to nothing and the flag stays off there.

### 2.3 S1.2: backend fixup (flag-gated, generated side)

In `runEcoBackend`, immediately after the marker expansions and the existing
scratch-helper gc-leaf loop (`EcoBackend.cpp:1462–1470`), before ANY RS4GC
flavour and before partition splitting, when `ECO_PRESERVE_CC=1`
(getenv-style, mirroring `ECO_INLINE_ALLOC` / `ECO_SLOT_CAST_BARRIERS`;
**default OFF for the experiment**):

```cpp
// {symbol, CC} table mirroring §2.2 exactly — the two sides must not drift.
for (auto &[name, cc] : kPreserveCCTable) {
    Function *f = m.getFunction(name);
    if (!f) continue;
    f->setCallingConv(cc);
    for (User *u : f->users())
        if (auto *cb = dyn_cast<CallBase>(u); cb && cb->getCalledFunction() == f)
            cb->setCallingConv(cc);
}
```

LLVM treats call-site/callee CC mismatch as UB, so the walk must catch every
call — assert post-walk that no `ccc` user of a table symbol remains.

### 2.4 S1.3: correctness gates (all flag-on)

1. Full E2E: `cmake --build build --target full` — all tests green.
2. `ECO_HEAP_VALIDATE` leg of the suite (helpers sit on GC-critical paths).
3. Clean-env Stage-7a bootstrap to fixed point. MLIR is untouched by this
   plan (LLVM-level only), so `--text-mlir` identity vs baseline should hold;
   the *binary* differs, byte-identity of the executable is not expected.
4. Asm spot-check on one partition (`objdump -d`): (a) preserve_most helper
   prologues save the registers their bodies use; (b) a hot function with a
   bump diamond no longer pushes callee-saved regs solely on account of the
   `eco_bump_state` call.

### 2.5 S1.4: measurement and verdict

Interleaved A/B per the proven protocol (`inline-nursery-allocation.md` §8 /
Run R): standard cold Stage-7a self-compile workload, warm-up leg discarded,
`eco-stuff` purged per leg, interleaved ×3 per side, **record major-GC counts
with each wall figure and re-run any leg where majors differ** (the
major-trigger-lottery lesson). The only delta between legs is
`ECO_PRESERVE_CC=0/1` — same binaries otherwise (§1.3).

Verdict gate:

- **Win (≥ ~1 % wall, consistent across the interleave):** flip
  `ECO_PRESERVE_CC` default-on, keep the C++ attributes, proceed to Step 2.
  Add an invariant row (ABI/LLVM family): *"Runtime helper symbols carrying a
  non-C calling convention must have the matching attribute on the
  RuntimeExports.h declaration AND on every generated call site
  (kPreserveCCTable); the safe mismatch direction is
  attribute-on-definition + ccc-call, never the reverse."*
- **Flat or regression:** revert the backend table and flag wiring entirely
  (user pattern: no dead experiment code); the header attributes may stay
  (harmless per §1.3) or go with it — default remove. Record the verdict
  here and in the memory index.

### 2.6 S1b (stretch, only if bump_state's clobbers dominate the S1 win)

Replace the `eco_bump_state` call with a direct TLS access
(`llvm.threadlocal.address` on an exported `thread_local` bump-state pointer)
— no call at all. Risks that keep this out of the main experiment:
`Allocator::instance()` indirection has to be hoisted into a plain exported
TLS symbol, and the TLS model must work under BOTH the JIT path and
AOT static linking (initial-exec vs local-dynamic). Only worth it with S1
evidence; `preserve_all` already captures most of the value.

---

## 3. Step 2 — follow-up: the statepointed slow calls (gated on Step 1 win)

### 3.1 S2.0: verify the statepoint CC plumbing first

RS4GC's `makeStatepointExplicit` copies the original call's CC onto the
`gc.statepoint`, and SelectionDAG statepoint lowering honors it — verify on
THIS LLVM (21.1.8) before building anything: run a bump diamond through the
real pipeline with a preserve_all `eco_alloc_inline_slow` and confirm in the
emitted asm that (a) the STATEPOINT call carries the convention (no
caller-side GPR saves on the slow edge beyond the statepoint's own gc-pointer
spills) and (b) the id/deopt bundle machinery is unaffected. If the CC is
dropped anywhere in the statepoint path, Step 2 dies here at zero cost.

### 3.2 S2.1: apply

- `ECO_PRESERVE_ALL` on `eco_alloc_inline_slow` (`RuntimeExports.cpp:194`)
  and `eco_list_tail_hybrid` (`:4182`), header + definition; add both to
  `kPreserveCCTable`. `preserve_all` (not `_most`) because the cost is
  amortized once per nursery block and it also rescues live f64s (xmm).
  The callee runs a full minor GC, so its prologue saves everything — that
  is hundreds of bytes of saves executed once per thousands of allocations.
- Expectation honestly capped per §"Why": GC-pointer relocation spills
  remain by necessity; the win is confined to non-GC values live across the
  38.6K diamonds plus regalloc no longer splitting around the cold edge.

### 3.3 S2.2: gates and verdict

Same gates as §2.4 (E2E full, HEAP_VALIDATE, bootstrap, asm spot-check of a
diamond slow edge) and the same §2.5 A/B protocol, this time flag-on-with-S2
vs flag-on-without-S2 (isolate Step 2's own contribution). Keep at ≥ ~0.5–1 %
additional wall, else revert the S2 table entries and attributes and close
the plan with Step 1 as the shipped surface.

---

## 4. Rollback story

Every piece is independently revertible: the env flag (default-off until a
verdict), the backend table (single site), the header macro applications
(pure attribute additions). No MLIR, no representation, no heap-layout
change anywhere — REP_*/HEAP_* invariants structurally untouched; the only
new coupling is the §2.5 invariant row if we ship.
