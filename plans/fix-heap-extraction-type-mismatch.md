# Plan: Fix Heap Extraction Type Mismatch

## Problem Summary

When extracting values from custom ADTs, the code declares primitive types (like `i64`) but the actual heap extraction returns `eco.value` (boxed). This causes SSA type mismatches.

**Error patterns:**
```
eco.return (opN): operand 0 ('%X'): _operand_types declares i64 but SSA type is eco.value
eco.papExtend (opN): operand 0 ('%X'): _operand_types declares eco.value but SSA type is i64
```

**Affected tests:** 7 failures in OperandTypeConsistencyTest

---

## Root Cause

`generateMonoPath` handles `CustomContainer` projections without knowing:
1. Which specific constructor we're projecting from
2. Whether the field at that index is stored boxed or unboxed

It passes `targetType` directly as the projection result type, but the heap may store a different representation.

---

## Critical Invariant: Projection Type Must Match Physical Storage

| `field.isUnboxed` | Physical Storage | Project as... | Then... |
|-------------------|------------------|---------------|---------|
| `True` | Primitive bits (i64/f64/etc) | Primitive type | Box if caller needs eco.value |
| `False` | `!eco.value` pointer | `eco.value` | Unbox if caller needs primitive |

**Why this matters:**
- If `isUnboxed = False` and you project as `i64`: You're interpreting a heap pointer as an integer → garbage/crash
- If `isUnboxed = True` and you project as `eco.value`: You're interpreting raw bits as a pointer → segfault

---

## Architecture Context

### CtorLayout Infrastructure

Each constructor has its own layout:

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
    , monoType : MonoType
    , isUnboxed : Bool
    }
```

**Critical:** For multi-constructor types like `Result Ok Err`, each constructor has its OWN `CtorLayout`. Field 0 in `Ok` is NOT the same as field 0 in `Err`.

### TypeRegistry Storage

```elm
type alias TypeRegistry =
    { ...
    , ctorLayouts : EveryDict.Dict (List String) (List String) (List Mono.CtorLayout)
        -- type key -> list of CtorLayouts (one per constructor)
    }
```

### Current MonoPath Limitation

```elm
type MonoPath
    = MonoIndex Int ContainerKind MonoPath  -- No constructor identity or container type!
    | MonoField Int MonoPath
    | MonoUnbox MonoPath
    | MonoRoot Name
```

When we hit `MonoIndex _ CustomContainer subPath`, we don't know:
- The container's `MonoType` (needed to find the type's layouts)
- Which constructor we matched (needed to select the right `CtorLayout`)

### Elm Tuple Limit

Elm only supports tuples up to size 3. This means:
- `HintUnknown` and the "large tuple" code path are effectively dead code
- `HintCustom` and `CustomContainer` are ONLY used for custom ADTs
- No need for a separate "anonymous large tuple" case

---

## Solution: Thread Constructor Identity AND Container Type

The fix requires changes at **two levels**: the `TOpt` IR (where paths are created) and the `Mono` IR (where code is generated).

---

### Step 1: Extend TOpt.ContainerHint to carry constructor name

**File:** `compiler/src/Compiler/AST/TypedOptimized.elm:293`

**Current:**
```elm
type ContainerHint
    = HintList
    | HintTuple2
    | HintTuple3
    | HintCustom
    | HintUnknown
```

**New:**
```elm
type ContainerHint
    = HintList
    | HintTuple2
    | HintTuple3
    | HintCustom Name.Name  -- Constructor name for layout lookup
    -- HintUnknown removed (crash if encountered anywhere)
```

**Cascading:** Update all pattern matches, update bytes encoding/decoding.

---

### Step 2: Update destructCtorArg to thread constructor name

**File:** `compiler/src/Compiler/Optimize/Typed/Expression.elm:1285`

**Current:**
```elm
destructCtorArg : ExprTypes -> TOpt.Path -> List TOpt.Destructor -> Can.PatternCtorArg -> Names.Tracker (List TOpt.Destructor)
destructCtorArg exprTypes path revDs (Can.PatternCtorArg index argType arg) =
    destructHelpWithType exprTypes Nothing (Just argType) (TOpt.Index index TOpt.HintCustom path) arg revDs
```

**New:**
```elm
destructCtorArg : ExprTypes -> Name.Name -> TOpt.Path -> List TOpt.Destructor -> Can.PatternCtorArg -> Names.Tracker (List TOpt.Destructor)
destructCtorArg exprTypes ctorName path revDs (Can.PatternCtorArg index argType arg) =
    destructHelpWithType exprTypes Nothing (Just argType) (TOpt.Index index (TOpt.HintCustom ctorName) path) arg revDs
```

---

### Step 3: Update PCtor handling in destructHelpWithType

**File:** `compiler/src/Compiler/Optimize/Typed/Expression.elm:1221`

Change `Can.PCtor { union, args }` to `Can.PCtor { union, name, args }` and pass `name` through all code paths:

```elm
Can.PCtor { union, name, args } ->
    case args of
        [ Can.PatternCtorArg _ argType arg ] ->
            ...
            Can.Normal ->
                destructHelpWithType ... (TOpt.Index Index.first (TOpt.HintCustom name) path) ...
            Can.Enum ->
                destructHelpWithType ... (TOpt.Index Index.first (TOpt.HintCustom name) path) ...
            ...
        _ ->
            ...
            List.foldl (\arg -> Names.andThen (\revDs_ -> destructCtorArg exprTypes name path revDs_ arg))
            ...
```

---

### Step 4: Extend Mono.ContainerKind to carry constructor name

**File:** `compiler/src/Compiler/AST/Monomorphized.elm:446`

**Current:**
```elm
type ContainerKind
    = ListContainer
    | Tuple2Container
    | Tuple3Container
    | CustomContainer
```

**New:**
```elm
type ContainerKind
    = ListContainer
    | Tuple2Container
    | Tuple3Container
    | CustomContainer Name.Name  -- Constructor name for layout lookup
```

**Cascading:** Update all pattern matches, bytes encoding/decoding.

---

### Step 5: Extend MonoPath to carry result types

**File:** `compiler/src/Compiler/AST/Monomorphized.elm:458`

**Current:**
```elm
type MonoPath
    = MonoIndex Int ContainerKind MonoPath
    | MonoField Int MonoPath
    | MonoUnbox MonoPath
    | MonoRoot Name
```

**New:**
```elm
type MonoPath
    = MonoIndex Int ContainerKind MonoType MonoPath  -- MonoType = RESULT type after projection
    | MonoField Int MonoType MonoPath                 -- MonoType = RESULT type after field access
    | MonoUnbox MonoPath
    | MonoRoot Name MonoType                          -- MonoType = variable's type
```

The `MonoType` at each node is the RESULT type of evaluating that path segment.
In `generateMonoPath`, the container type for a `MonoIndex` is obtained via `getMonoPathType subPath`.

**Cascading:** Update all pattern matches, bytes encoding/decoding.

---

### Step 6: Add getMonoPathType helper

**File:** `compiler/src/Compiler/AST/Monomorphized.elm`

```elm
{-| Get the result type of evaluating a MonoPath. -}
getMonoPathType : MonoPath -> MonoType
getMonoPathType path =
    case path of
        MonoRoot _ ty -> ty
        MonoIndex _ _ ty _ -> ty
        MonoField _ ty _ -> ty
        MonoUnbox subPath -> getMonoPathType subPath
```

---

### Step 7: Add computeProjectionResultType helper

**File:** `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm`

```elm
{-| Compute the result type after projecting from a container.
    For CustomContainer, looks up the union definition and finds the field type.
-}
computeProjectionResultType : TypeEnv.GlobalTypeEnv -> Mono.ContainerKind -> Int -> Mono.MonoType -> Mono.MonoType
computeProjectionResultType globalTypeEnv kind index containerType =
    case kind of
        Mono.ListContainer ->
            case containerType of
                Mono.MList elemType ->
                    if index == 0 then elemType  -- head
                    else containerType  -- tail is still a list
                _ ->
                    Utils.Crash.crash ("computeProjectionResultType: expected MList, got " ++ Debug.toString containerType)

        Mono.Tuple2Container ->
            case containerType of
                Mono.MTuple layout ->
                    case List.drop index layout.elements |> List.head of
                        Just ( elemType, _ ) -> elemType
                        Nothing -> Utils.Crash.crash "computeProjectionResultType: tuple2 index out of range"
                _ ->
                    Utils.Crash.crash "computeProjectionResultType: expected MTuple for Tuple2Container"

        Mono.Tuple3Container ->
            case containerType of
                Mono.MTuple layout ->
                    case List.drop index layout.elements |> List.head of
                        Just ( elemType, _ ) -> elemType
                        Nothing -> Utils.Crash.crash "computeProjectionResultType: tuple3 index out of range"
                _ ->
                    Utils.Crash.crash "computeProjectionResultType: expected MTuple for Tuple3Container"

        Mono.CustomContainer ctorName ->
            lookupCtorFieldType globalTypeEnv containerType ctorName index


{-| Look up field type for a custom type constructor. -}
lookupCtorFieldType : TypeEnv.GlobalTypeEnv -> Mono.MonoType -> Name.Name -> Int -> Mono.MonoType
lookupCtorFieldType globalTypeEnv containerType ctorName index =
    case containerType of
        Mono.MCustom canonical typeName typeArgs ->
            let
                union = lookupUnion globalTypeEnv canonical typeName
                (Can.Union unionData) = union
                -- Build substitution from type vars to concrete args
                varSubst = List.map2 Tuple.pair unionData.vars typeArgs |> Dict.fromList identity
                -- Find the constructor
                ctor = findCtor ctorName unionData.alts
                (Can.Ctor ctorData) = ctor
                -- Get field type and substitute type variables
                fieldCanType =
                    case List.drop index ctorData.args |> List.head of
                        Just t -> t
                        Nothing -> Utils.Crash.crash ("lookupCtorFieldType: field index " ++ String.fromInt index ++ " out of range")
            in
            TypeSubst.applySubstToCanType varSubst fieldCanType

        _ ->
            Utils.Crash.crash ("lookupCtorFieldType: expected MCustom, got " ++ Debug.toString containerType)


{-| Look up a union definition from the global type environment. -}
lookupUnion : TypeEnv.GlobalTypeEnv -> IO.Canonical -> Name.Name -> Can.Union
lookupUnion globalTypeEnv canonical typeName =
    case Dict.get (ModuleName.toComparableCanonical canonical) globalTypeEnv of
        Just moduleEnv ->
            case Dict.get typeName moduleEnv.unions of
                Just union -> union
                Nothing -> Utils.Crash.crash ("lookupUnion: union " ++ typeName ++ " not found")
        Nothing ->
            Utils.Crash.crash ("lookupUnion: module not found")


{-| Find a constructor by name in a list of constructors. -}
findCtor : Name.Name -> List Can.Ctor -> Can.Ctor
findCtor ctorName ctors =
    case List.filter (\(Can.Ctor data) -> data.name == ctorName) ctors |> List.head of
        Just ctor -> ctor
        Nothing -> Utils.Crash.crash ("findCtor: constructor " ++ ctorName ++ " not found")
```

---

### Step 8: Update hintToKind to thread constructor name

**File:** `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm:1494`

**Current:**
```elm
hintToKind hint =
    case hint of
        ...
        TOpt.HintCustom ->
            Mono.CustomContainer
        TOpt.HintUnknown ->
            Mono.CustomContainer
```

**New:**
```elm
hintToKind : TOpt.ContainerHint -> Mono.ContainerKind
hintToKind hint =
    case hint of
        TOpt.HintList ->
            Mono.ListContainer

        TOpt.HintTuple2 ->
            Mono.Tuple2Container

        TOpt.HintTuple3 ->
            Mono.Tuple3Container

        TOpt.HintCustom ctorName ->
            Mono.CustomContainer ctorName
```

Note: `HintUnknown` is removed entirely. If encountered anywhere, the compiler will error on the missing pattern match.

---

### Step 9: Update specializePath to compute types

**File:** `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm:1473`

**Current:**
```elm
specializePath : TOpt.Path -> Mono.MonoPath
specializePath path =
    case path of
        TOpt.Index index hint subPath ->
            Mono.MonoIndex (Index.toMachine index) (hintToKind hint) (specializePath subPath)
        ...
```

**New:**
```elm
specializePath : TOpt.Path -> VarTypes -> TypeEnv.GlobalTypeEnv -> Mono.MonoPath
specializePath path varTypes globalTypeEnv =
    case path of
        TOpt.Root name ->
            let
                rootType =
                    case Dict.get name varTypes of
                        Just ty -> ty
                        Nothing -> Utils.Crash.crash ("specializePath: variable not found: " ++ name)
            in
            Mono.MonoRoot name rootType

        TOpt.Index index hint subPath ->
            let
                subMonoPath = specializePath subPath varTypes globalTypeEnv
                containerType = Mono.getMonoPathType subMonoPath
                kind = hintToKind hint
                resultType = computeProjectionResultType globalTypeEnv kind (Index.toMachine index) containerType
            in
            Mono.MonoIndex (Index.toMachine index) kind resultType subMonoPath

        TOpt.Field fieldName subPath ->
            let
                subMonoPath = specializePath subPath varTypes globalTypeEnv
                recordType = Mono.getMonoPathType subMonoPath
                ( fieldIndex, resultType ) = getRecordFieldInfo recordType fieldName
            in
            Mono.MonoField fieldIndex resultType subMonoPath

        TOpt.Unbox subPath ->
            Mono.MonoUnbox (specializePath subPath varTypes globalTypeEnv)

        TOpt.ArrayIndex _ _ ->
            Utils.Crash.crash "specializePath: ArrayIndex should not appear (Elm tuples are max size 3)"
```

---

### Step 10: Update specializeDestructor to pass globalTypeEnv

**File:** `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm:1461`

**Current:**
```elm
specializeDestructor : TOpt.Destructor -> Substitution -> VarTypes -> Mono.MonoDestructor
specializeDestructor (TOpt.Destructor name path canType) subst _ =
    let
        monoPath = specializePath path
        monoType = TypeSubst.applySubst subst canType
    in
    Mono.MonoDestructor name monoPath monoType
```

**New:**
```elm
specializeDestructor : TOpt.Destructor -> Substitution -> VarTypes -> TypeEnv.GlobalTypeEnv -> Mono.MonoDestructor
specializeDestructor (TOpt.Destructor name path canType) subst varTypes globalTypeEnv =
    let
        monoPath = specializePath path varTypes globalTypeEnv
        monoType = TypeSubst.applySubst subst canType
    in
    Mono.MonoDestructor name monoPath monoType
```

**Update caller at line ~947:**
```elm
monoDestructor = specializeDestructor destructor subst state.varTypes state.globalTypeEnv
```

---

### Step 11: Add isPrimitiveType to Types.elm

**File:** `compiler/src/Compiler/Generate/MLIR/Types.elm`

```elm
{-| Check if a type is a primitive (i64, f64, i16, i1).
    These types can be stored unboxed in heap objects.
-}
isPrimitiveType : MlirType -> Bool
isPrimitiveType ty =
    case ty of
        I64 -> True
        F64 -> True
        I16 -> True
        I1 -> True
        _ -> False
```

---

### Step 12: Add layout lookup helpers for MLIR generation

**File:** `compiler/src/Compiler/Generate/MLIR/Patterns.elm` (or Context.elm)

```elm
{-| Look up the CtorLayout for a specific constructor of a custom type. -}
lookupCtorLayout : Ctx.Context -> Mono.MonoType -> Name.Name -> Mono.CtorLayout
lookupCtorLayout ctx monoType ctorName =
    let
        key = Mono.toComparableMonoType monoType
        allLayouts =
            EveryDict.get identity key ctx.typeRegistry.ctorLayouts
                |> Maybe.withDefault []
        matchingLayout =
            List.filter (\layout -> layout.name == ctorName) allLayouts
                |> List.head
    in
    case matchingLayout of
        Just layout -> layout
        Nothing ->
            Utils.Crash.crash
                ("lookupCtorLayout: No layout for ctor " ++ ctorName ++ " in " ++ Debug.toString monoType)


{-| Get FieldInfo for a field index from a CtorLayout. Validates index matches. -}
getFieldInfo : Int -> Mono.CtorLayout -> Mono.FieldInfo
getFieldInfo index ctorLayout =
    case List.drop index ctorLayout.fields |> List.head of
        Just fieldInfo ->
            if fieldInfo.index /= index then
                Utils.Crash.crash
                    ("getFieldInfo: index mismatch - expected " ++ String.fromInt index
                     ++ " but FieldInfo.index is " ++ String.fromInt fieldInfo.index)
            else
                fieldInfo
        Nothing ->
            Utils.Crash.crash
                ("getFieldInfo: index " ++ String.fromInt index ++ " out of range for " ++ ctorLayout.name)
```

---

### Step 13: Update generateMonoPath for layout-aware projection

**File:** `compiler/src/Compiler/Generate/MLIR/Patterns.elm:34`

**New CustomContainer case:**
```elm
Mono.MonoIndex index (Mono.CustomContainer ctorName) resultType subPath ->
    let
        -- Navigate to container (always !eco.value)
        ( subOps, subVar, ctx1 ) =
            generateMonoPath ctx subPath Types.ecoValue

        ( resultVar, ctx2 ) =
            Ctx.freshVar ctx1

        -- Container type is what subPath evaluates to
        containerType =
            Mono.getMonoPathType subPath

        -- Look up the CtorLayout for this specific constructor
        ctorLayout =
            lookupCtorLayout ctx containerType ctorName

        -- Get field info for this index
        fieldInfo =
            getFieldInfo index ctorLayout
    in
    if fieldInfo.isUnboxed then
        -- Field is stored UNBOXED - heap slot physically holds primitive bits
        if Types.isEcoValueType targetType then
            -- Caller needs eco.value from unboxed primitive - project then box
            let
                primitiveType =
                    Types.monoTypeToMlir fieldInfo.monoType

                ( projectVar, ctx2a ) =
                    Ctx.freshVar ctx2

                ( ctx3, projectOp ) =
                    Ops.ecoProjectCustom ctx2a projectVar index primitiveType subVar

                ( boxOps, boxedVar, ctx4 ) =
                    Intrinsics.boxToEcoValue ctx3 projectVar primitiveType
            in
            ( subOps ++ [ projectOp ] ++ boxOps, boxedVar, ctx4 )

        else
            -- Caller needs primitive - project directly to primitive type
            let
                ( ctx3, projectOp ) =
                    Ops.ecoProjectCustom ctx2 resultVar index targetType subVar
            in
            ( subOps ++ [ projectOp ], resultVar, ctx3 )

    else
        -- Field is stored BOXED - heap slot holds !eco.value pointer
        -- ALWAYS project as eco.value (that's what's physically there!)
        if Types.isPrimitiveType targetType then
            -- Caller needs primitive - project as eco.value, then unbox
            let
                ( projectVar, ctx2a ) =
                    Ctx.freshVar ctx2

                ( ctx3, projectOp ) =
                    Ops.ecoProjectCustom ctx2a projectVar index Types.ecoValue subVar

                ( unboxOps, unboxedVar, ctx4 ) =
                    Intrinsics.unboxToType ctx3 projectVar targetType
            in
            ( subOps ++ [ projectOp ] ++ unboxOps, unboxedVar, ctx4 )

        else
            -- Caller needs eco.value - project directly as eco.value
            let
                ( ctx3, projectOp ) =
                    Ops.ecoProjectCustom ctx2 resultVar index Types.ecoValue subVar
            in
            ( subOps ++ [ projectOp ], resultVar, ctx3 )
```

---

### Step 14: Move boxToEcoValue to Intrinsics.elm

**From:** `compiler/src/Compiler/Generate/MLIR/Expr.elm:793`
**To:** `compiler/src/Compiler/Generate/MLIR/Intrinsics.elm`

This pairs it with `unboxToType` for consistency.

---

### Step 15: Update all cascading pattern matches and serialization

Search and update all pattern matches:
```bash
grep -r "HintCustom\|HintUnknown\|ContainerHint" compiler/src compiler/tests
grep -r "MonoIndex\|MonoField\|MonoRoot\|CustomContainer\|ContainerKind" compiler/src compiler/tests
```

Update bytes encoding/decoding in:
- `compiler/src/Compiler/AST/TypedOptimized.elm` (ContainerHint encoder/decoder)
- `compiler/src/Compiler/AST/Monomorphized.elm` (ContainerKind, MonoPath encoders/decoders)

---

## Files to Modify Summary

| File | Change |
|------|--------|
| `Compiler/AST/TypedOptimized.elm` | Extend `ContainerHint` with ctor name, remove `HintUnknown` |
| `Compiler/Optimize/Typed/Expression.elm` | Update `destructCtorArg` and PCtor handling to thread ctor name |
| `Compiler/AST/Monomorphized.elm` | Extend `ContainerKind` with ctor name, extend `MonoPath` with `MonoType`, add `getMonoPathType` |
| `Compiler/Generate/Monomorphize/Specialize.elm` | Update `hintToKind`, `specializePath`, `specializeDestructor`; add type computation helpers |
| `Compiler/Generate/MLIR/Patterns.elm` | Update `generateMonoPath` for layout-aware projection; add layout lookup helpers |
| `Compiler/Generate/MLIR/Types.elm` | Add `isPrimitiveType` helper |
| `Compiler/Generate/MLIR/Intrinsics.elm` | Move `boxToEcoValue` from Expr.elm |
| `Compiler/Generate/MLIR/Expr.elm` | Remove `boxToEcoValue` (moved to Intrinsics) |

---

## Test Commands

```bash
# Targeted tests for this fix
cd /work/compiler
timeout 10 npx elm-test --fuzz 1 tests/Compiler/Generate/CodeGen/OperandTypeConsistencyTest.elm

# Full CodeGen suite
for f in tests/Compiler/Generate/CodeGen/*Test.elm; do
  timeout 5 npx elm-test --fuzz 1 "$f"
done
```

---

## Expected Impact

- **OperandTypeConsistencyTest:** 7 failures should be fixed
- **Type mismatch errors:** Both error patterns resolved:
  - `_operand_types declares i64 but SSA type is eco.value` (projecting boxed as primitive)
  - `_operand_types declares eco.value but SSA type is i64` (projecting unboxed as eco.value)

---

## Design Principle Alignment

1. **Update context mapping when representation changes** - Explicit `eco.unbox`/`eco.box` when converting between representations
2. **Never re-interpret an SSA value with a different type** - Project to actual heap type, then convert
3. **Use layout metadata** - Leverage `CtorLayout` with constructor name to get correct `isUnboxed` flag
4. **No fallbacks** - Crash explicitly if layout lookup fails rather than guessing

---

## Risk Assessment

**Medium risk** - scope is significant but design is sound:

1. Extending `MonoPath` and `ContainerKind` touches many files
2. Requires threading constructor identity and types through specialization
3. Need to handle all pattern matches on extended types
4. Bytes encoding/decoding must be updated

**Mitigations:**
1. Compiler will catch missing pattern matches immediately
2. Existing tests will verify behavior
3. Validators catch type mismatches early
4. Explicit crashes instead of fallbacks ensure bugs are visible
