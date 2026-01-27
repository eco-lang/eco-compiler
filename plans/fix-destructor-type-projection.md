# Fix Destructor Type Projection for Closure Arguments

## Problem Summary

When `Result.andThen half (Ok 42)` is executed:
1. The value `42` is extracted from `Ok` via `eco.project.custom` as `i64`
2. But then it's **boxed back to `!eco.value`** because the destructor's type variable maps to `!eco.value`
3. The boxed HPointer is passed to `papExtend` and stored in the closure
4. The wrapper passes the HPointer to `half(i64)`, which treats it as an integer → wrong result

## Root Cause (VERIFIED)

### Investigation Results

Debug output from `specializeDestructor`:
```
canType = TVar "value"
subst = { a -> Result String Int, b -> MInt, x -> MString }
monoType = MVar "value" CEcoValue
```

**The problem**: The `canType` in the `TOpt.Destructor` is `TVar "value"` (from the Result type definition: `type Result error value = Ok value | Err error`), but the substitution map has type variables `a`, `b`, `x` (from the function signature: `andThen : (a -> Result x b) -> Result x a -> Result x b`).

### Type Variable Name Mismatch

The type flows as follows:
1. During canonicalization, `PatternCtorArg` stores the generic type from the constructor definition (`TVar "value"`)
2. During type inference, the type checker unifies types but uses variables from the function context (`a`, `b`, `x`)
3. During monomorphization, `TypeSubst.applySubst` looks up `"value"` in the substitution but only finds `"a"`, `"b"`, `"x"`
4. Since `"value"` is not in the substitution, it becomes `MVar "value" CEcoValue`
5. `monoTypeToAbi (MVar _ CEcoValue)` returns `!eco.value`, causing boxing

### Source of the Bug

**File**: `compiler/src/Compiler/Optimize/Typed/Expression.elm`
**Function**: `destructCtorArg`

```elm
destructCtorArg exprTypes ctorName path revDs (Can.PatternCtorArg index argType arg) =
    destructHelpWithType exprTypes Nothing (Just argType) ...
```

The function passes `argType` (the generic type from the constructor definition) instead of looking up the actual inferred type from `exprTypes`.

## The Fix

In `destructCtorArg`, instead of using `argType` from `PatternCtorArg`, look up the pattern's actual inferred type from `exprTypes` using the pattern's ID:

```elm
destructCtorArg exprTypes ctorName path revDs (Can.PatternCtorArg index _argType arg) =
    let
        -- Get the actual inferred type from the pattern, not the generic type from constructor
        patternId = (A.toValue arg).id
        actualType =
            case Dict.get identity patternId exprTypes of
                Just t -> Just t
                Nothing -> Nothing  -- Fall back to no type hint
    in
    destructHelpWithType exprTypes Nothing actualType (TOpt.Index index (TOpt.HintCustom ctorName) path) arg revDs
```

This ensures the destructor gets the concrete type (`Int`) instead of the generic type variable (`value`).

## Files to Modify

1. `compiler/src/Compiler/Optimize/Typed/Expression.elm` - `destructCtorArg` function

## Testing

1. Run the failing test:
   ```bash
   TEST_FILTER=elm-core/ResultAndThenTest cmake --build build --target check
   ```

2. Run full test suite to check for regressions:
   ```bash
   cmake --build build --target check
   ```

3. Run Elm frontend tests:
   ```bash
   cd compiler && npx elm-test --fuzz 1
   ```

## Risk Assessment

- **Low risk**: The fix is localized to a single function
- **Low complexity**: Simple change to use inferred types instead of generic types
- **Testing coverage**: Existing test suite should catch regressions
