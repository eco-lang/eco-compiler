# Function-parallel EcoToLLVM conversion — feasibility & design (M7 follow-up)

Status: **DESIGN / NOT SCHEDULED.** Spun out of round-4 milestone M7
(`plans/backend-spine-round4-optimizations.md`). M7 shipped env-gated
sub-phase timers in `EcoToLLVMPass::runOnOperation` (`ECO_ECO2LLVM_STATS`);
this doc records what they revealed and what a parallelization would require.

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
