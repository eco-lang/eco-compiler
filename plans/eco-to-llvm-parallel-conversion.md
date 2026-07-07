# Function-parallel EcoToLLVM conversion — feasibility & design (M7 follow-up)

Status: **IMPLEMENTED, VALIDATED & DEFAULT-ON (2026-07-07) — IT SCALES.** Contrary
to this doc's original "blocked / not-a-win" prior, the two-stage scheme below was
built and measures a **5.9× speedup on Stage 2 (4376ms→737ms)**, **−3.46s serial-vs-
parallel wall**, **−2.6s (−9.8%) net vs the round-4 baseline** (26.4→23.8s).
**Now the DEFAULT** (post-validation): per-function body conversion runs parallel
whenever the MLIRContext has multithreading enabled; `ECO_ECO2LLVM_PARALLEL=0`
is the escape hatch to force serial (determinism bisection / debugging). Measured
on the self-host boot module: default MLIR pipeline 8.16s / EcoToLLVMPass 4.69s vs
forced-serial 12.29s / 8.54s; default output byte-identical to both forced modes.
Full result + the four bugs found on the way: `backendstats-round4.txt` (Phase 2 section).
Key deviations from the plan below that made it work: runtime decls are
pre-declared-all + stripped (via `SymbolUserMap`, NOT `symbolKnownUseEmpty` which
was O(decls×module)=213s); eval-layouts could NOT be exactly pre-derived so they
live in a dedicated `DenseSet`+`std::mutex` OUTSIDE the (lock-free) symCache;
Stage 2 uses chunked `failableParallelForEach` with per-chunk converter/patterns.

## Validation sweep (2026-07-07, follow-up) — PASSED (+ 1 determinism bug fixed)

**Bottom line:** parallel EcoToLLVM is functionally correct and, after the
eval-layout ordering fix below, byte-reproducible. The full native bootstrap
under `ECO_ECO2LLVM_PARALLEL=1` PASSES end-to-end (Stage 8c byte-exact
fixed-point holds; unified `eco` self-compiles a working `eco-2`).


- **Full E2E (parallel on):** 1547/1547 (one transient `construct_large_unboxed_
  bitmap` failure was a known `~/.eco` cache race, not a parallel regression —
  passes 10/10 standalone, serial-vs-parallel JIT output byte-identical).
- **GC-stress:** the runtime GC property + codegen + `.elm` suite, `ECO_ECO2LLVM_
  PARALLEL=1` + tiny nursery (8-block) + `-n 15` (14.7M allocs, 318 MB churn):
  **1547/1547 PASSED**.
- **IR-identity (the rigorous GC-metadata proof):** `ecoc --emit=mlir-llvm` over
  the whole self-host module, serial vs parallel, split into 98 658 top-level
  defs → **sorted-hash multisets EQUAL**. Every function body (incl. all 84 291
  `garbageCollector="eco-gc"` attrs + shadow roots), every global bit-identical.
  The ONLY diff is the *textual order* of module-level eval-layout globals
  (registered first-come across threads) — semantically inert.
- **Determinism + a PRE-EXISTING bug found & fixed:** the first full-bootstrap
  run under parallel FAILED at Stage 8c (native byte-exact fixed-point,
  `eco-compiler-boot != eco-compiler-boot-2`). Root-caused: with `--split-codegen=1`
  (deterministic single-partition emit) and even in **fully-serial** mode, the
  pure EcoToLLVM IR (`--emit=mlir-llvm`) was non-deterministic run-to-run — but
  the 98 658-def sorted multiset was EQUAL, i.e. the ONLY diff was the *textual
  order* of `__eco_eval_layout_*` globals. Eval-layouts are the one artifact
  created on demand (`ensureEvalLayoutGlobal`); their emission order tracks
  StringAttr-keyed demand-discovery order (pointer/hash dependent), so it varied
  even without parallelism — a latent Stage-8c flake that parallel merely made
  more visible, NOT caused by. **Fix (EcoToLLVM.cpp serial epilogue): sort the
  `__eco_eval_layout_*` globals into a canonical by-name block, anchored before
  the first non-layout op.** After the fix, at the default (bootstrap) config
  `serial==serial`, `parallel==parallel`, AND `serial==parallel` ELF are ALL
  byte-IDENTICAL — eco-boot-native is now byte-reproducible and Stage 8c holds.
  (NB: at `-O2` `serial==serial` still differs — that is a *separate*, pre-existing
  parallel *object-emission* (lazy-split) non-determinism, out of scope here; the
  default/bootstrap config is deterministic.)
- **Fastest-compile flag sweep** (self-host mlir→native, 24-core): `-O 2
  --parallel-opt=dev` + `ECO_ECO2LLVM_PARALLEL=1` → **24.2 s** wall (LLVM backend
  65.8→7.9 s), a **3.57× / −72%** vs the 86.5 s whole-module-`-O2` baseline;
  `--parallel-opt=cgu` keeps full `-O2` quality at 24.8 s. `--rs4gc-after-opt`
  adds nothing here (24.19 vs 24.22 s).

Original design notes follow (M7 shipped env-gated `ECO_ECO2LLVM_STATS` timers).

## Why this pass is worth attacking

`EcoToLLVMPass` is the single largest **serial** item in the MLIR phase
(~5.0–5.3s of a ~28s dev build; module-anchored, runs on one thread). The
rest of the round-4 wins chip at the spine; this is the one remaining
multi-second serial block whose work (per-function dialect conversion) is
embarrassingly parallel in principle.

## Measured stage breakdown (ECO_ECO2LLVM_STATS, self-host module)

Measured 2026-07-07 (self-host module, `ECO_ECO2LLVM_STATS=1`, dev):
```
1. pattern population/setup       :   36.0 ms   (0.7%)
2. lowerAllocGroups               :   15.5 ms   (0.3%)
3. applyFullConversion            : 4402.2 ms  (89.7%)  <-- DOMINANT
4. GC-strategy + shadow-root walks:  232.8 ms   (4.7%)
5. createGlobalRootInitFunction   :  220.4 ms   (4.5%)
                                    --------
                            total  : 4906.9 ms
```

**Decision: PROCEED-eligible.** `applyFullConversion` is 89.7% — well past
the 70% bar. The other four stages sum to ~10% (~505 ms), so there is no
point touching them; the entire lever is the per-function pattern application
inside `applyFullConversion`. This is exactly the case the two-stage scheme
below targets.

## The two-stage scheme (IF stage 3 dominates)

Serial prologue (thread 0) → parallel per-function body conversion (N threads):

1. **Serial prologue** — everything that mutates module-level state:
   - function *signature* conversion (`func::FuncOp` → `LLVM::LLVMFuncOp`
     op-replacement — a module-region structural mutation, MUST stay serial);
   - ALL module-level artifact creation (runtime decls, string-literal /
     string-case / type-table / eval-layout globals, closure wrappers);
   - populate `EcoRuntime`'s caches to a frozen, read-only state.
2. **Parallel** — convert each function *body* independently: pattern
   application that reads (never writes) the frozen prologue state.
3. **Serial epilogue** — `createGlobalRootInitFunction` (already post-
   conversion; compatible unchanged).

## HARD BLOCKERS (module-mutation inventory — verified via M7 grep)

Function-parallel body conversion is blocked TODAY by two classes of shared
state. Every item here must be hoisted into the serial prologue (or made
thread-safe) before any parallel section is sound:

### A. Shared mutable `EcoRuntime` (not thread-safe)
- `EcoToLLVMInternal.h:254` `mutable ModuleOp module`
- `EcoToLLVMInternal.h:259` `mutable DenseMap symCache` — read+written by
  `cacheSymbol` (:293-297) and `ensureSymCache`/`lookupSymbol` (:283-314),
  no lock.
- `EcoToLLVMInternal.h:278` `mutable uint64_t stringLiteralCounter` — bumped
  at `EcoToLLVMTypes.cpp:90` (must become atomic or move to prologue).
- `EcoToLLVMInternal.h:~279` `mutable StringMap utf16PatternCache` (added by
  M5c) — same treatment.

### B. Patterns that fabricate module-level funcs/globals at `module.getBody()`
- **getOrCreateFunc chokepoint** `EcoToLLVMRuntime.cpp:122-146`
  (`setInsertionPointToStart(module.getBody())` :132, `create<LLVMFuncOp>`
  :133, `cacheSymbol` :144) — ALL ~150 `getOrCreate{Alloc,Init,Store,Closure,
  Utility}*` methods funnel through it; reachable from nearly every heap/
  closure/arith/errordebug pattern. Concurrent calls race on both insertion
  and `symCache`.
- string-literal globals `EcoToLLVMTypes.cpp:89-100`.
- string-case globals `EcoToLLVMControlFlow.cpp:395-405` (the M5c site).
- eval-layout globals `EcoToLLVMClosures.cpp:1350-1386` (`getOrCreateEvalLayout`).
- `GlobalOpLowering` `EcoToLLVMGlobals.cpp:24-52`; `TypeTableOpLowering`
  fabricates the whole type-table global cluster `EcoToLLVMGlobals.cpp:108+`.
- kernel-decl func creation `EcoToLLVMFunc.cpp:83-94` (+ `eraseOp(funcOp)` :94
  — a module-region structural mutation).
- closure wrapper/extern funcs `EcoToLLVMClosures.cpp:244-382`
  (`getOrCreateWrapper`, invoked from PapCreate/PapCreateGroup lowerings).
- `populateFuncToLLVMConversionPatterns` (`EcoToLLVM.cpp:284`) does the
  `func::FuncOp`→`LLVM::LLVMFuncOp` op-replacement — prerequisite (c): serial.

### Already-serial / compatible
- `createGlobalRootInitFunction` (`EcoToLLVMGlobals.cpp:465+`) runs post-
  conversion as stage 5 (not from a pattern) — fine unchanged.

## ⚠ Cross-cutting risk (do not skip)

This is the **same hazard family as the PARKED `EcoTailConversions.cpp`
Heisenbug** (garbage `std::function` captures in the JIT path → memory
corruption, 176/288 codegen fails even single-threaded, masked by an
address-of). Any custom parallel conversion driver must root-cause that
first — MLIR's `applyFullConversion` is not designed for concurrent mutation
of one module, so a bespoke per-function driver + a frozen-`EcoRuntime`
contract is required, and the capture-lifetime bug that bit EcoTailConversions
would bite here too.

## Recommended sequencing (if pursued)

1. Establish the frozen-`EcoRuntime` contract: a `freeze()` that asserts no
   writes to `symCache`/counters during the parallel section (debug builds).
2. Hoist inventory A+B into the serial prologue; prove (assert) zero module
   mutation from any pattern during a single-threaded dry run.
3. Only then introduce the parallel body-conversion driver, N=cores, each
   function in its own `IRRewriter`, sharing the frozen read-only prologue.
4. Gate: full E2E + AOT dev/cgu sweep + self-host byte-identity, plus
   ECO_HEAP_VALIDATE GC-stress (this pass sets GC strategy + shadow roots).

Estimated ceiling: stage 3 (~<t3>s) → ~1.5–2.5s at N≈cores, i.e. ~2.5–3s off
the serial spine. Effort: 1–3 weeks + the Heisenbug root-cause. Not scheduled;
this doc is the entry point when it is.
