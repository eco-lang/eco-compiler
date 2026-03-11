# MONO_024 and MONO_025 Invariant Tests

## Overview

Implement invariant tests for two new monomorphization invariants:
- **MONO_024**: Fully monomorphic specializations have no CEcoValue in reachable MonoTypes
- **MONO_025**: Closure MonoType matches specialization key

## Implementation Plan

### MONO_024: FullyMonomorphicNoCEcoValue

**Files to create:**
1. `compiler/tests/TestLogic/Monomorphize/FullyMonomorphicNoCEcoValue.elm` - Logic
2. `compiler/tests/TestLogic/Monomorphize/FullyMonomorphicNoCEcoValueTest.elm` - Test wrapper

**Approach:**
- Follow the MONO_021 (NoCEcoValueInUserFunctions) pattern closely
- Iterate `registry.reverseMapping` to get specialization keys
- Skip Nothing entries (pruned) and entries whose key MonoType is not fully monomorphic
  (contains MVar or MErased)
- For fully monomorphic entries, traverse the implementing MonoNode's entire expression
  tree collecting all MonoTypes
- Check each MonoType for CEcoValue MVar via `Mono.containsCEcoMVar`
- Report violations with specId, key type, and the offending MonoType

**Key helpers needed:**
- `isFullyMonomorphic : MonoType -> Bool` (local helper: not containsAnyMVar and not containsMErased)
- `containsMErased : MonoType -> Bool` (new helper, same structure as containsAnyMVar)
- Recursive `checkExpr` collecting violations from all expression types (reuse pattern from MONO_021)

### MONO_025: ClosureSpecKeyConsistency

**Files to create:**
1. `compiler/tests/TestLogic/Monomorphize/ClosureSpecKeyConsistency.elm` - Logic
2. `compiler/tests/TestLogic/Monomorphize/ClosureSpecKeyConsistencyTest.elm` - Test wrapper

**Approach:**
- Iterate `registry.reverseMapping` to get (Global, keyMonoType, maybeLambdaId)
- Skip Nothing entries, non-closure nodes (MonoCtor, MonoEnum, MonoExtern, MonoManagerLeaf)
- For MonoTailFunc and MonoDefine(MonoClosure): extract closure param types and result type
- Flatten the key MonoType to get expected param types and result type
- Compare the closure's param types against the key's param type prefix
- For fully saturated closures, also compare result types
- For closures returning functions, verify the result type matches remaining key structure

**Key helpers needed:**
- `flattenMFunction : MonoType -> (List MonoType, MonoType)` - recursively peel MFunction layers
- `monoTypeEq : MonoType -> MonoType -> Bool` - structural equality (treating MVar(CEcoValue) and MErased as equal)

### Test Registration

Both test modules need to be registered in `compiler/tests/elm-test-rs-tests.elm`
(or equivalent test runner entry point).

### Running Tests

```bash
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1
```
