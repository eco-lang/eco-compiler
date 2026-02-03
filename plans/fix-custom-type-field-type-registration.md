# Fix Custom Type Constructor Field Type Registration

## Problem Statement

When registering a custom type like `Point Int Int` in the type registry, the `registerNestedTypes` function in `Context.elm` only registers **type arguments** (e.g., the `a` in `Maybe a`), but does NOT register **constructor field types** from `ctorShapes`.

### Current Behavior (Buggy)

For `type Point = Point Int Int`:

```mlir
types = [[0, 4, 0, 1]]     -- Only type 0 (Custom: Point), no Int type
fields = [[1, 0], [2, 0]]  -- Both fields reference type_id=0 (WRONG!)
```

The `Int` field types are never registered, so `lookupTypeId` returns `0` (the default), which happens to be the `Point` custom type's own ID.

### Expected Behavior

```mlir
types = [[0, 0, 0], [1, 4, 0, 1]]  -- Type 0: Int, Type 1: Point
fields = [[1, 0], [2, 0]]          -- Both fields reference type_id=0 (Int) - CORRECT
```

---

## Root Cause

In `compiler/src/Compiler/Generate/MLIR/Context.elm`, the `registerNestedTypes` function for `Mono.MCustom`:

```elm
Mono.MCustom _ _ args ->
    -- Register all type argument types
    List.foldl
        (\argType accCtx ->
            Tuple.second (getOrCreateTypeIdForMonoType argType accCtx)
        )
        ctx
        args
```

Only registers type arguments (`args`), which are empty for concrete types like `Point Int Int`. The constructor field types (`Int`, `Int`) are stored in `ctorShapes` but never registered.

---

## Implementation

### Step 1: Add helper function in `Context.elm`

Add `registerCustomCtorFieldTypes` immediately above `registerNestedTypes`:

```elm
{-| Register all constructor field types for a custom type.

This uses the pre-computed ctorShapes map from monomorphization to
find the Mono.CtorShape entries for the given MCustom and ensures all
field types are registered in the TypeRegistry before the custom type
itself gets a TypeId.

We must be careful about recursive custom types: if a field's type is
the same as the containing type, we skip it here to avoid infinite
recursion.
-}
registerCustomCtorFieldTypes : Mono.MonoType -> Context -> Context
registerCustomCtorFieldTypes monoType ctx =
    let
        key =
            Mono.toComparableMonoType monoType

        ctorShapesForType : List Mono.CtorShape
        ctorShapesForType =
            EveryDict.get identity key ctx.typeRegistry.ctorShapes
                |> Maybe.withDefault []

        registerFieldTypesForCtor :
            Mono.CtorShape -> Context -> Context
        registerFieldTypesForCtor ctorShape accCtx =
            List.foldl
                (\fieldType innerCtx ->
                    -- Avoid infinite recursion on directly recursive fields:
                    if Mono.toComparableMonoType fieldType
                        == Mono.toComparableMonoType monoType
                    then
                        innerCtx

                    else
                        Tuple.second (getOrCreateTypeIdForMonoType fieldType innerCtx)
                )
                accCtx
                ctorShape.fieldTypes
    in
    List.foldl registerFieldTypesForCtor ctx ctorShapesForType
```

### Step 2: Update `registerNestedTypes` for `Mono.MCustom`

Replace the existing `Mono.MCustom` branch:

```elm
Mono.MCustom _ _ args ->
    -- First, register all type argument types (e.g. the `a` in Maybe a)
    let
        ctxWithArgs =
            List.foldl
                (\argType accCtx ->
                    Tuple.second (getOrCreateTypeIdForMonoType argType accCtx)
                )
                ctx
                args

        -- Then, register all constructor field types for this concrete
        -- MCustom instance using the pre-computed ctorShapes map.
        ctxWithFields =
            registerCustomCtorFieldTypes monoType ctxWithArgs
    in
    ctxWithFields
```

---

## Key Design Decisions

### Recursion Safety

For self-recursive types like `type List a = Nil | Cons a (List a)`:
- The `List a` field type has the same comparable key as the containing type
- We skip such fields to prevent infinite recursion
- The type graph still correctly represents recursive edges via TypeId references

### Order of Registration

1. First register type arguments (for polymorphic customs like `Maybe Int`)
2. Then register constructor field types (for all customs)
3. This ensures field types are in `typeIds` before `TypeTable.addCtorInfo` runs

---

## Files to Modify

| File | Changes |
|------|---------|
| `compiler/src/Compiler/Generate/MLIR/Context.elm` | Add `registerCustomCtorFieldTypes` helper; update `Mono.MCustom` branch in `registerNestedTypes` |

---

## Testing

### Primary Tests
- `CustomTypeMultiFieldTest` should pass (currently SIGABRT)
- `SimpleMultiFieldTest` should pass (currently SIGABRT)

### Regression Tests
- `MaybeJustTest` should continue to pass (polymorphic custom type)
- `CustomTypeBasicTest` should continue to pass (zero-field constructors)
- All existing elm-core tests should pass

### Verification Commands
```bash
# Run specific failing test
TEST_FILTER=CustomTypeMultiFieldTest cmake --build build --target check

# Run all custom type tests
TEST_FILTER=CustomType cmake --build build --target check

# Run all elm-core tests
TEST_FILTER=elm-core cmake --build build --target check

# Run compiler unit tests
cd compiler && npx elm-test-rs --fuzz 1
```

---

## Success Criteria

1. `CustomTypeMultiFieldTest` passes with correct output: `person: Person "Alice" 30 True`
2. Generated MLIR type table shows correct field type IDs (primitive IDs, not custom type ID)
3. All existing elm-core tests continue to pass
4. No stack overflow on recursive custom types
