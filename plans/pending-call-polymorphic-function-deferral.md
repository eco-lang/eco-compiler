# Plan: Defer PendingCall Only for Polymorphic Function Results (Section 3.1 Option A + 3.2)

## Goal

Fix remaining combinator test failures by narrowing the `PendingCall` trigger in `processCallArg`
so that only nested calls returning **polymorphic function types** (containing CEco MVars) are deferred.
Non-function polymorphic results are specialized eagerly.

## Current State

- **File**: `compiler/src/Compiler/Monomorphize/Specialize.elm`
- **Line 2529**: The `TOpt.Call` branch currently defers ANY call whose result `monoType` has
  `Mono.containsCEcoMVar monoType == True`, regardless of whether the result is a function type.
- **`resolveProcessedArg`** (line 2673): Already implements section 3.2 correctly — uses
  `unifyExtend` to refine the substitution from the outer callee's parameter type, then
  re-specializes. No changes needed here.
- **`Mono.containsCEcoMVar`** exists at `compiler/src/Compiler/AST/Monomorphized.elm:357`.
- **`callResultNeedsPending`** does not yet exist.

## Steps

### Step 1: Add `callResultNeedsPending` helper

**Where**: `Specialize.elm`, above `processCallArgs` (around line 2410).

```elm
callResultNeedsPending : Mono.MonoType -> Bool
callResultNeedsPending monoType =
    case monoType of
        Mono.MFunction _ _ ->
            Mono.containsCEcoMVar monoType

        _ ->
            False
```

This returns `True` only when the result is `MFunction` AND contains CEco MVars.

### Step 2: Replace the condition on line 2529

**Change**: Replace `Mono.containsCEcoMVar monoType` with `callResultNeedsPending monoType`.

Before:
```elm
            if Mono.containsCEcoMVar monoType then
```

After:
```elm
            if callResultNeedsPending monoType then
```

Update the comment from "still polymorphic" to "a polymorphic function" for clarity.

### Step 3: No changes to `resolveProcessedArg`

The existing `PendingCall` branch at line 2673 already implements section 3.2 correctly.
Verify it still works with the narrowed trigger by reviewing the logic (no code change).

### Step 4: Build and run combinator tests

```bash
cmake --build build --target full
```

Then filter for combinator tests:
```bash
TEST_FILTER=Combinator cmake --build build --target full
```

Expected to fix:
- CombinatorBComposeTest
- CombinatorCFlipTest
- CombinatorCConsTest
- CombinatorBSumMapTest
- CombinatorSpMulTest
- CombinatorTThrushTest
- CombinatorTPipeTest
- CombinatorTest
- CombinatorListStringTest

### Step 5: Verify no regressions in other tests

Run the full E2E suite to confirm non-combinator tests still pass.

## Files Modified

| File | Change |
|------|--------|
| `compiler/src/Compiler/Monomorphize/Specialize.elm` | Add `callResultNeedsPending`, change condition on line 2529 |

## Resolved Questions

### Q1: Non-combinator tests and the narrower deferral

**No known regressions expected.** Non-function polymorphic results (e.g., `List a` with unresolved
`a`) could previously become `PendingCall` and get one more `unifyExtend` via the outer parameter
type. However, `refineSubstFromArgExprs` already covers most "arg is more specific than scheme"
cases for non-functions. No known non-combinator tests require deferral for non-function results;
all failing E2Es are higher-order combinator patterns.

**Fallback**: If something breaks, extend `callResultNeedsPending` to cover specific non-function
shapes (e.g., containers with lambdas), or add a targeted Pending variant for those cases.

### Q2: Combinator test baseline

**Passing (7):**
- CombinatorIIdentityTest
- CombinatorSFeedTest
- CombinatorSpCombineTest
- CombinatorWDupTest
- CombinatorWConcatTest
- CombinatorPLengthsTest
- CombinatorSPalindromeTest

**Failing (9) — expected to fix:**
- CombinatorBComposeTest
- CombinatorCFlipTest
- CombinatorCConsTest
- CombinatorBSumMapTest
- CombinatorSpMulTest
- CombinatorTThrushTest
- CombinatorTPipeTest
- CombinatorTest
- CombinatorListStringTest

The 7 passing tests are simpler/fully-applied uses that don't stress partial-application typing.

### Q3: Can `MFunction` with CEco MVars appear where deferral is wrong?

**No, in practice.** Two cases:

- **Kernels**: Kernel uses go through `TOpt.VarKernel` / `PendingKernel`, not `TOpt.Call` /
  `PendingCall`. The "kernel returns `a -> b` but outer provides no `maybeParamType`" scenario
  doesn't arise via this path.

- **Regular nested calls**: `PendingCall` is only used when a nested `TOpt.Call` is an argument.
  In `resolveProcessedArgs`, `maybeParamType` is drawn from the outer callee's parameter list.
  For well-typed code (including combinators), arities match, so we get `Just paramType` and
  refine the substitution.

  The only time `maybeParamType = Nothing` is when we ran out of outer params (more args than
  params). In that degenerate case, `PendingCall` falls back to `savedSubst` — behavior is no
  worse than the old eager path. If we ever hit this in practice, adding a debug assert there
  would be reasonable.

## Assumptions

- `resolveProcessedArg` `PendingCall` branch handles `maybeParamType = Nothing` gracefully
  (falls back to `savedSubst`) — confirmed by reading line 2681-2683.
- `Mono.MFunction` is the only function-type constructor in `MonoType`. No other variant
  (e.g., a type alias) can represent a function type at this stage.
- The change is purely in the trigger condition; no structural changes to `ProcessedArg`,
  `resolveProcessedArg`, or any other function.
