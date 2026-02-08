# Plan: MONO_013 CtorShape ↔ CtorLayout Consistency Test

## Overview

This plan implements a proper MONO_013 test that validates constructor layout consistency. The test has two parts:

1. **CtorShape ↔ CtorLayout consistency**: Verify that when `Types.computeCtorLayout` is applied to a `CtorShape`, the resulting `CtorLayout` has consistent field counts, ordering, and unboxed flags.

2. **MonoCtor nodes use known shapes**: Verify that every `MonoCtor` node in the graph references a `CtorShape` that exists in `ctorShapes`.

## Key Insight: MVar CEcoValue Is Allowed

The previous test incorrectly flagged `MVar` types in `CtorShape.fieldTypes`. This is wrong because:

- **Polymorphic types** may have `MVar` in their field types (e.g., `Identity a` has field type `a`)
- `MVar` types are **always boxed** (never unboxed) per `canUnbox` which only returns `True` for `MInt`, `MFloat`, `MChar`
- The invariant is **not** "no MVars after monomorphization"
- The invariant **is** "CtorLayout is consistent with CtorShape and all unboxing decisions are valid"

## Current State

### CtorShape (in Monomorphized.elm)
```elm
type alias CtorShape =
    { name : Name
    , tag : Int
    , fieldTypes : List MonoType
    }
```

### CtorLayout (in Types.elm)
```elm
type alias CtorLayout =
    { name : Name
    , tag : Int
    , fields : List FieldInfo
    , unboxedCount : Int
    , unboxedBitmap : Int
    }

type alias FieldInfo =
    { name : Name
    , index : Int
    , monoType : Mono.MonoType
    , isUnboxed : Bool
    }
```

### computeCtorLayout (in Types.elm)
```elm
computeCtorLayout shape =
    let
        fields =
            List.indexedMap
                (\idx ty ->
                    { name = "field" ++ String.fromInt idx
                    , index = idx
                    , monoType = ty
                    , isUnboxed = canUnbox ty
                    }
                )
                shape.fieldTypes
        -- ... computes unboxedBitmap and unboxedCount
    in
    { name = shape.name, tag = shape.tag, fields = fields, ... }
```

### canUnbox (in Types.elm)
```elm
canUnbox monoType =
    case monoType of
        Mono.MInt -> True
        Mono.MFloat -> True
        Mono.MChar -> True
        _ -> False
```

## What MONO_013 Must Check

1. **Field count**: `List.length shape.fieldTypes == List.length layout.fields`
2. **Field ordering**: Field at index `i` in shape corresponds to field at index `i` in layout
3. **Unboxed flags**: For each field:
   - If `isUnboxed = True`, the type must be `MInt`, `MFloat`, or `MChar`
   - If type is `MVar`, then `isUnboxed` must be `False`
4. **MonoCtor shape exists**: Every `MonoCtor` node's shape must exist in `ctorShapes`

## What MONO_013 Must NOT Check

- **NO**: Reject `MVar` in `fieldTypes` - polymorphic types are valid
- **NO**: Require full monomorphization of all types - some remain polymorphic
- **NO**: Check unboxedBitmap computation - that's CGEN-level validation

## Affected Files

| Action | File |
|--------|------|
| **REWRITE** | `compiler/tests/TestLogic/Monomorphize/MonoCtorLayoutIntegrity.elm` |
| Optional | `design_docs/invariant-test-logic.md` (update description) |

## Implementation

### Part 1: checkCtorShapesAgainstLayouts

For each `CtorShape` in `graph.ctorShapes`:
1. Compute `CtorLayout` via `Types.computeCtorLayout`
2. Verify field count matches
3. Verify each field's `isUnboxed` flag is valid

```elm
checkCtorShapesAgainstLayouts : Dict (List String) (List String) (List Mono.CtorShape) -> List Violation
checkCtorShapesAgainstLayouts ctorShapes =
    Dict.foldl compare
        (\typeKey shapes acc ->
            List.concatMap (checkShapeAgainstLayout typeKey) shapes ++ acc
        )
        []
        ctorShapes


checkShapeAgainstLayout : List String -> Mono.CtorShape -> List Violation
checkShapeAgainstLayout typeKey shape =
    let
        layout = Types.computeCtorLayout shape
        context = "CtorShape " ++ shape.name ++ " (type: " ++ String.join "." typeKey ++ ")"
    in
    -- Check field count consistency
    if List.length shape.fieldTypes /= List.length layout.fields then
        [ { context = context
          , message = "MONO_013 violation: Field count mismatch between shape and layout"
          }
        ]
    else
        -- Check unboxed flags are valid
        checkUnboxedFlags context layout.fields
```

### Part 2: checkUnboxedFlags

For each field in layout, verify `isUnboxed` is only `True` for `MInt`, `MFloat`, `MChar`:

```elm
checkUnboxedFlags : String -> List Types.FieldInfo -> List Violation
checkUnboxedFlags context fields =
    List.filterMap
        (\field ->
            if field.isUnboxed && not (isUnboxable field.monoType) then
                Just
                    { context = context
                    , message =
                        "MONO_013 violation: Field "
                            ++ String.fromInt field.index
                            ++ " marked unboxed but type is "
                            ++ monoTypeToString field.monoType
                            ++ " (only Int, Float, Char can be unboxed)"
                    }
            else
                Nothing
        )
        fields


isUnboxable : Mono.MonoType -> Bool
isUnboxable monoType =
    case monoType of
        Mono.MInt -> True
        Mono.MFloat -> True
        Mono.MChar -> True
        _ -> False
```

### Part 3: checkCtorNodesUseKnownShapes

For each `MonoCtor` node, verify its shape exists in `ctorShapes`:

```elm
checkCtorNodesUseKnownShapes : Mono.MonoGraph -> List Violation
checkCtorNodesUseKnownShapes (Mono.MonoGraph data) =
    Dict.foldl compare
        (\specId node acc ->
            case node of
                Mono.MonoCtor shape _ ->
                    if shapeExistsInDict shape data.ctorShapes then
                        acc
                    else
                        { context = "SpecId " ++ String.fromInt specId
                        , message =
                            "MONO_013 violation: MonoCtor uses shape '"
                                ++ shape.name
                                ++ "' not found in ctorShapes"
                        }
                            :: acc
                _ ->
                    acc
        )
        []
        data.nodes


shapeExistsInDict : Mono.CtorShape -> Dict (List String) (List String) (List Mono.CtorShape) -> Bool
shapeExistsInDict targetShape ctorShapes =
    Dict.foldl compare
        (\_ shapes found ->
            found || List.any (\s -> s.name == targetShape.name && s.tag == targetShape.tag) shapes
        )
        False
        ctorShapes
```

### Main Check Function

```elm
checkMonoCtorLayoutIntegrity : Mono.MonoGraph -> List Violation
checkMonoCtorLayoutIntegrity (Mono.MonoGraph data) =
    let
        layoutViolations = checkCtorShapesAgainstLayouts data.ctorShapes
        nodeViolations = checkCtorNodesUseKnownShapes (Mono.MonoGraph data)
    in
    layoutViolations ++ nodeViolations
```

## Import Requirements

The test module needs to import `Types.elm` for `computeCtorLayout`:

```elm
import Compiler.Generate.MLIR.Types as Types
```

## Verification

After implementation:

```bash
cd compiler
npx elm-test-rs --fuzz 1 -- tests/TestLogic/Monomorphize/MonoCtorLayoutIntegrityTest.elm
```

## Summary

| Step | Action | Description |
|------|--------|-------------|
| 1 | Rewrite checker | Replace MVar rejection with CtorLayout consistency checks |
| 2 | Add layout import | Import `Compiler.Generate.MLIR.Types` for `computeCtorLayout` |
| 3 | Implement Part 1 | `checkCtorShapesAgainstLayouts` verifies field count and ordering |
| 4 | Implement Part 2 | `checkUnboxedFlags` verifies only Int/Float/Char are unboxed |
| 5 | Implement Part 3 | `checkCtorNodesUseKnownShapes` verifies MonoCtor shapes exist |
| 6 | Run tests | Verify all tests pass including polymorphic type cases |

## What This Catches

- **Invalid unboxing**: A field marked `isUnboxed = True` for a non-primitive type
- **Missing shapes**: A `MonoCtor` referencing a shape not in `ctorShapes`
- **Field count mismatches**: Shape and layout having different field counts

## What This Allows

- **MVar in fieldTypes**: Polymorphic types like `Identity a` with `MVar` fields
- **Boxed MVar fields**: As long as `isUnboxed = False`, any type including `MVar` is valid
