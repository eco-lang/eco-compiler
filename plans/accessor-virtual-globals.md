# Accessor Virtual Globals Implementation Plan

## Overview

Transform `.field` accessors from special-case `MonoAccessor` expressions into virtual global functions that flow through the standard specialization pipeline. This eliminates the MLIR-side accessor machinery and ensures accessors receive fully-resolved record types.

## Problem

When accessors like `.name` are used as first-class functions (e.g., `List.map .name records`):
- Arguments are monomorphized BEFORE call-site type unification
- This causes the accessor to receive an incomplete record type (just `{name: String}` instead of `{name: String, age: Int}`)
- The accessor then generates code for the wrong field index

## Solution: Option A - Accessors as Virtual Globals

At Mono level: `.name` is a **virtual global function** `Accessor "name"` that gets specialized like any other `Global`.

At MLIR level: accessors are just **normal specialized functions** backed by `MonoTailFunc` nodes; there is no special `PendingAccessor` / `generateAccessor` machinery.

---

## Phase 1: Extend the `Global` Type

### Step 1.1: Add `Accessor` constructor to `Global`
**File:** `compiler/src/Compiler/AST/Monomorphized.elm`

```elm
type Global
    = Global IO.Canonical Name
    | Accessor Name
```

### Step 1.2: Update `toComparableGlobal`
**File:** `compiler/src/Compiler/AST/Monomorphized.elm`

```elm
toComparableGlobal : Global -> List String
toComparableGlobal global =
    case global of
        Global home name ->
            "Global" :: ModuleName.toComparableCanonical home ++ [ name ]

        Accessor fieldName ->
            [ "Accessor", fieldName ]
```

---

## Phase 2: Update Monomorphization to Specialize Accessors

### Step 2.1: Change `TOpt.Accessor` handling in `specializeExpr`
**File:** `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm`

Replace:
```elm
TOpt.Accessor region fieldName canType ->
    let
        monoType =
            TypeSubst.applySubst subst canType
    in
    ( Mono.MonoAccessor region fieldName monoType, state )
```

With:
```elm
TOpt.Accessor region fieldName canType ->
    let
        monoType =
            TypeSubst.applySubst subst canType

        accessorGlobal =
            Mono.Accessor fieldName

        ( specId, newRegistry ) =
            Mono.getOrCreateSpecId accessorGlobal monoType Nothing state.registry

        newState =
            { state
                | registry = newRegistry
                , worklist = SpecializeGlobal accessorGlobal monoType Nothing :: state.worklist
            }
    in
    ( Mono.MonoVarGlobal region specId monoType, newState )
```

### Step 2.2: Add `Accessor` branch in `processWorklist`
**File:** `compiler/src/Compiler/Generate/Monomorphize.elm`

Branch on `global` BEFORE calling `monoGlobalToTOpt`:
```elm
case global of
    Mono.Accessor fieldName ->
        -- Handle accessor specialization
        let
            ( monoNode, stateAfter ) =
                specializeAccessorGlobal fieldName monoType state2
            ...
        in
        ...

    Mono.Global _ _ ->
        -- Existing logic with monoGlobalToTOpt and toptNodes lookup
        ...
```

### Step 2.3: Implement `specializeAccessorGlobal`
**File:** `compiler/src/Compiler/Generate/Monomorphize.elm`

```elm
specializeAccessorGlobal : Name -> Mono.MonoType -> MonoState -> ( Mono.MonoNode, MonoState )
specializeAccessorGlobal fieldName monoType state =
    case monoType of
        Mono.MFunction [ Mono.MRecord layout ] fieldType ->
            let
                ( fieldIndex, isUnboxed ) =
                    lookupFieldIndex fieldName (Mono.MRecord layout)

                paramName = "record"
                recordType = Mono.MRecord layout

                bodyExpr =
                    Mono.MonoRecordAccess
                        (Mono.MonoVarLocal paramName recordType)
                        fieldName
                        fieldIndex
                        isUnboxed
                        fieldType
            in
            ( Mono.MonoTailFunc [ ( paramName, recordType ) ] bodyExpr monoType, state )

        _ ->
            Utils.Crash.crash "..." "..." "Expected MFunction [MRecord ...] fieldType"
```

---

## Phase 3: Remove `MonoAccessor` from the AST

### Step 3.1: Remove `MonoAccessor` constructor
**File:** `compiler/src/Compiler/AST/Monomorphized.elm`

- Delete `| MonoAccessor Region Name MonoType` from `MonoExpr`
- Delete the `MonoAccessor` case from `typeOf`

### Step 3.2: Update pattern matches
**Files:**
- `compiler/src/Compiler/Generate/Monomorphize/Closure.elm` - remove `Mono.MonoAccessor` from `extractRegion`
- `compiler/src/Compiler/Generate/MLIR/Expr.elm` - remove `Mono.MonoAccessor` from `generateExpr`
- `compiler/src/Compiler/Generate/Monomorphize/Analysis.elm` - remove from `collectCustomTypesFromExpr`

---

## Phase 4: Clean Up MLIR Backend

### Step 4.1: Remove `PendingAccessor` from Context
**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`

- Remove `PendingAccessor` type alias
- Remove `pendingAccessors` field from `Context`
- Remove from exports
- Update `initContext`

### Step 4.2: Remove accessor processing from Lambdas
**File:** `compiler/src/Compiler/Generate/MLIR/Lambdas.elm`

- Remove `processPendingAccessors` function
- Remove `generateAccessorFunc` function
- Remove from module exports

### Step 4.3: Remove accessor call from Backend
**File:** `compiler/src/Compiler/Generate/MLIR/Backend.elm`

- Remove `processPendingAccessors` call
- Remove `accessorOps` from module body

### Step 4.4: Remove `generateAccessor` from Expr
**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

- Remove `generateAccessor` function
- Remove from module exports

---

## Phase 5: Update MLIR Symbol Naming

### Step 5.1: Extend `specIdToFuncName` for Accessor globals
**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

```elm
specIdToFuncName registry specId =
    case Mono.lookupSpecKey specId registry of
        Just ( Mono.Global home name, _, _ ) ->
            canonicalToMLIRName home ++ "_" ++ sanitizeName name ++ "_$_" ++ String.fromInt specId

        Just ( Mono.Accessor fieldName, _, _ ) ->
            "accessor_" ++ sanitizeName fieldName ++ "_$_" ++ String.fromInt specId

        Nothing ->
            "unknown_$_" ++ String.fromInt specId
```

---

## Phase 6: Testing

```bash
TEST_FILTER=elm cmake --build build --target full
```

Verify:
- `RecordAccessorFunctionTest.elm` passes
- No `addressof` errors remain
- No regressions in other tests

---

## Key Design Decisions

1. **Parameter name**: Use `"record"` for consistency with existing patterns
2. **Field lookup**: Use `f.index` from `FieldInfo` via existing `lookupFieldIndex` helper
3. **No regions needed**: `MonoRecordAccess` and `MonoVarLocal` don't carry regions
4. **Symbol naming**: `accessor_<fieldName>_$_<specId>` ensures uniqueness per specialization
