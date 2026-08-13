# Kernel-Opt 15: Float-reachability stamps — make allocation dedup NaN-sound

**Status: IMPLEMENTATION 2026-08-13.** Born from item 13's reverted CSE flip
(`benchmarks/kernel-opt.md` Run R addendum): merging two structurally identical
NaN-containing allocations is observable through the equality kernel's
pointer-fast-path, so `[Pure]` on allocating ops licenses a miscompile. This
item makes the merge licence type-aware and then retries the flip, fulfilling
the standing "default CSE to on" instruction soundly.

## Design (from the review discussion, family 2)

**Invariant being restored:** the pointer-eq fast path assumes structural
equality is reflexive; NaN is the only non-reflexive leaf. Therefore sharing
may be INTRODUCED only into values that provably cannot reach a Float.

1. **`Mono.typeCanReachFloat : LayoutMap (List CtorShape) -> MonoType -> Bool`**
   — exact over monomorphized types; customs resolve through `ctorShapes`
   (fieldTypes) with a visited-set fixpoint; `MFunction`/`MVar` conservative
   True (closures make `==` crash, and sharing converts crash→True — same
   hazard class).
2. **Front end stamps `eco.float_free`** (UnitAttr, discardable) on the five
   construct ops when the constructed type is float-free, and on stamped
   kernel calls whose KernelFacts row carries the new audited axis
   `resultFloatFree` (conservative False default; True only for
   Order/Bool/Int/String-returning rows). Flag `floatFreeStamp`, DEFAULT-ON,
   env `ECO_FLOAT_FREE=0`, hash token `ffree=1`. Flag-off = no stamps = no
   merging of any allocation: the conservative direction.
3. **Backend: the Allocate-on-result split.** The five construct ops and
   `Eco_BoxOp` lose `[Pure]` and implement `MemoryEffectsOpInterface`:
   stamped (or box-of-non-f64, type-visible in C++) → no effects (merge +
   erase); unstamped → `MemoryEffects::Allocate` on the result — which MLIR's
   `wouldOpBeTriviallyDead` treats as **erasable-if-unused but never
   memory-effect-free**, so DCE keeps working everywhere and only MERGING is
   withheld. `CallOp::getEffects` becomes three-way: `cse_safe`+`float_free` →
   none; `cse_safe` alone → Allocate-on-results (erase-only — the DCE half of
   the licence never creates sharing); neither → conservative read+write.
4. **Mono CSE guard (discharges CSE_001's new clause):** `MonoCse.admit` and
   `CseCensus.admit` both refuse candidates whose result type can reach Float
   (counted as `floatExcluded` so census and pass stay in exact agreement).
5. **Retry the flip:** `ECO_MLIR_CSE` default ON; the three
   `ContainerEquality*FloatTest`s are the pin, run in the full battery under
   the new default. Race sound-CSE-on vs off as Run S.

## Gates

Full E2E under the new defaults; `ECO_MLIR_CSE=0` and `ECO_FLOAT_FREE=0` legs;
elm-tests (KernelFacts axis changes the table module; 13085/12 baseline);
frozen-corpus race with counters; stamp census (how much of the pool is
float-free — expected ≫95% on this workload).
