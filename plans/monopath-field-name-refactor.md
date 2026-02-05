# MonoPath: Store Field Name Instead of Index

## Problem

`Compiler.Monomorphize.Specialize` imports `Compiler.Generate.MLIR.Types` to use `computeRecordLayout` and `FieldInfo` when constructing `MonoField` path segments. This creates an improper dependency from an earlier compiler phase (Monomorphization) to a later one (MLIR codegen).

### Current Violation

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm` (line 30)
```elm
import Compiler.Generate.MLIR.Types as Types
```

**What is used:**
- `Types.computeRecordLayout` (line 1865)
- `Types.FieldInfo` (line 1880)

These are used in `computeFieldProjectionType` and `findFieldInLayout` to compute a field index for record pattern destructuring.

---

## Solution Overview

1. **Change `MonoField` constructor** to carry a field name (`Name`) instead of an index (`Int`)
2. **Simplify Specialize.elm** to look up field type directly from `MRecord` dictionary
3. **Move index resolution** to MLIR `Patterns.elm` where layout computation is already used

---

## Implementation

### Step 1: Update `MonoPath` Type

**File:** `compiler/src/Compiler/AST/Monomorphized.elm`

**Find:**
```elm
type MonoPath
    = MonoIndex Int ContainerKind MonoType MonoPath -- MonoType = result type after projection
    | MonoField Int MonoType MonoPath -- MonoType = result type after field access
    | MonoUnbox MonoType MonoPath -- MonoType = result type after unwrapping (the field type)
    | MonoRoot Name MonoType -- MonoType = variable's type
```

**Replace `MonoField` line with:**
```elm
    | MonoField Name MonoType MonoPath -- MonoType = result type after field access (record field by name)
```

**Note:** `getMonoPathType` pattern matches by position only, so no change needed there.

---

### Step 2: Remove MLIR.Types Import from Specialize.elm

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

**Delete:**
```elm
import Compiler.Generate.MLIR.Types as Types
```

---

### Step 3: Replace `TOpt.Field` Branch in `specializePath`

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

**Find the `TOpt.Field` branch (around line 1858-1868):**
```elm
        TOpt.Field fieldName subPath ->
            let
                monoSubPath =
                    specializePath subPath subst varTypes globalTypeEnv

                recordType =
                    Mono.getMonoPathType monoSubPath

                ( fieldIndex, resultType ) =
                    computeFieldProjectionType fieldName recordType
            in
            Mono.MonoField fieldIndex resultType monoSubPath
```

**Replace with:**
```elm
        TOpt.Field fieldName subPath ->
            let
                monoSubPath =
                    specializePath subPath subst varTypes globalTypeEnv

                recordType =
                    Mono.getMonoPathType monoSubPath

                resultType =
                    case recordType of
                        Mono.MRecord fields ->
                            case Dict.get identity fieldName fields of
                                Just fieldMonoType ->
                                    fieldMonoType

                                Nothing ->
                                    Utils.Crash.crash
                                        ("Specialize.specializePath: Field '" ++ fieldName
                                            ++ "' not found in record type. This is a compiler bug."
                                        )

                        _ ->
                            Utils.Crash.crash
                                ("Specialize.specializePath: Expected MRecord for field path but got: "
                                    ++ Mono.monoTypeToDebugString recordType
                                )
            in
            Mono.MonoField fieldName resultType monoSubPath
```

---

### Step 4: Delete Layout Helper Functions from Specialize.elm

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

**Delete `computeFieldProjectionType` (around lines 1872-1885):**
```elm
{-| Compute the field index and type from a record field access.
-}
computeFieldProjectionType : Name -> Mono.MonoType -> ( Int, Mono.MonoType )
computeFieldProjectionType fieldName recordType =
    case recordType of
        Mono.MRecord fields ->
            let
                layout =
                    Types.computeRecordLayout fields
            in
            case findFieldInLayout fieldName layout.fields of
                Just fieldInfo ->
                    ( fieldInfo.index, fieldInfo.monoType )

                Nothing ->
                    Utils.Crash.crash ("Specialize.computeFieldProjectionType: Field '" ++ fieldName ++ "' not found in record layout")

        _ ->
            Utils.Crash.crash ("Specialize.computeFieldProjectionType: Expected MRecord but got: " ++ Mono.monoTypeToDebugString recordType)
```

**Delete `findFieldInLayout` (around lines 1888-1899):**
```elm
{-| Find a field by name in a list of field infos.
-}
findFieldInLayout : Name -> List Types.FieldInfo -> Maybe Types.FieldInfo
findFieldInLayout targetName fields =
    case fields of
        [] ->
            Nothing

        fieldInfo :: rest ->
            if fieldInfo.name == targetName then
                Just fieldInfo

            else
                findFieldInLayout targetName rest
```

---

### Step 5: Update `generateMonoPath` in Patterns.elm

**File:** `compiler/src/Compiler/Generate/MLIR/Patterns.elm`

#### 5.1 Add Helper Function

Add near top of file (after imports):
```elm
getRecordFields : Mono.MonoType -> Dict.Dict String Name.Name Mono.MonoType
getRecordFields monoType =
    case monoType of
        Mono.MRecord fields ->
            fields

        _ ->
            Dict.empty


findFieldInfoByName : Name.Name -> List Types.FieldInfo -> Maybe Types.FieldInfo
findFieldInfoByName targetName fields =
    List.filter (\fi -> fi.name == targetName) fields
        |> List.head
```

#### 5.2 Update `MonoField` Branch

**Find the current `MonoField` branch:**
```elm
        Mono.MonoField index resultType subPath ->
            let
                -- Navigate to the container object (always !eco.value)
                ( subOps, subVar, ctx1 ) =
                    generateMonoPath ctx subPath Types.ecoValue

                ( resultVar, ctx2 ) =
                    Ctx.freshVar ctx1

                -- Project directly to the targetType using record projection.
                -- MonoField is generated from TOpt.Field which is record field access.
                -- Primitive types are stored unboxed and should be read directly.
                ( ctx3, projectOp ) =
                    Ops.ecoProjectRecord ctx2 resultVar index targetType subVar
            in
            ( subOps ++ [ projectOp ]
            , resultVar
            , ctx3
            )
```

**Replace with:**
```elm
        Mono.MonoField fieldName resultType subPath ->
            let
                -- Navigate to the container object (always !eco.value)
                ( subOps, subVar, ctx1 ) =
                    generateMonoPath ctx subPath Types.ecoValue

                ( resultVar, ctx2 ) =
                    Ctx.freshVar ctx1

                containerType =
                    Mono.getMonoPathType subPath

                layout =
                    Types.computeRecordLayout (getRecordFields containerType)

                fieldInfo =
                    findFieldInfoByName fieldName layout.fields
                        |> Maybe.withDefault
                            { name = fieldName
                            , index = 0
                            , monoType = resultType
                            , isUnboxed = False
                            }

                -- Project directly to the targetType using record projection.
                -- Primitive types are stored unboxed and should be read directly.
                ( ctx3, projectOp ) =
                    Ops.ecoProjectRecord ctx2 resultVar fieldInfo.index targetType subVar
            in
            ( subOps ++ [ projectOp ]
            , resultVar
            , ctx3
            )
```

---

## File Change Summary

| File | Change |
|------|--------|
| `compiler/src/Compiler/AST/Monomorphized.elm` | Change `MonoField Int` to `MonoField Name` |
| `compiler/src/Compiler/Monomorphize/Specialize.elm` | Remove import, simplify `TOpt.Field` branch, delete 2 helper functions |
| `compiler/src/Compiler/Generate/MLIR/Patterns.elm` | Add helpers, compute layout in `MonoField` branch |

---

## Verification

1. **Compiler tests:**
   ```bash
   cd compiler && npx elm-test-rs --fuzz 1
   ```

2. **E2E tests:**
   ```bash
   cmake --build build --target check
   ```

3. **Verify no improper imports remain:**
   ```bash
   grep -r "import Compiler.Generate.MLIR" compiler/src/Compiler/Monomorphize/
   # Should return no results
   ```

---

## Why This Works

**Before:** Monomorphization computed layout to get field index, which required importing MLIR.Types.

**After:**
- Monomorphization only needs the field's `MonoType`, which is available directly from `MRecord`'s dictionary
- The field index (a heap-layout concern) is computed during MLIR codegen in `Patterns.elm`, where `Types.computeRecordLayout` and `FieldInfo` are already legitimately used

This cleanly separates:
- **Semantic information** (field name, type) - available at monomorphization
- **Layout information** (field index, unboxing) - computed at codegen
