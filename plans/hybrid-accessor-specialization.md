# Hybrid A/C Accessor Specialization

## Problem Statement

When an accessor like `.name` is passed as an argument to a higher-order function like `List.map`, the monomorphizer currently specializes it eagerly using the substitution at the call site. This produces an accessor with an incomplete record type (e.g., `{ name : String }` instead of `{ name : String, age : Int }`), causing field index mismatches at runtime.

**Example that fails:**
```elm
people = [ { name = "Alice", age = 30 }, { name = "Bob", age = 25 } ]
List.map .name people
```

The accessor gets specialized to `{ name : String } -> String` instead of `{ name : String, age : Int } -> String`, producing incorrect field indices.

## Solution Overview

Implement a "hybrid A/C" approach:
- **Phase A (deferred binding):** Defer accessor argument specialization until after call-site type unification completes
- **Phase C (symbolic accessor):** Derive the accessor's monomorphic type from the fully-resolved function parameter type, not from the accessor's canonical type with incomplete row variables

## Current Codebase State

### Relevant Files

| File | Current State |
|------|---------------|
| `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm` | Main expression specialization; handles `TOpt.Call` (lines 786-869) and `TOpt.Accessor` (lines 932-949) |
| `compiler/src/Compiler/Generate/Monomorphize/TypeSubst.elm` | Has `unifyFuncCall`, `extractParamTypes`, `applySubst` - no changes needed |
| `compiler/src/Compiler/Generate/Monomorphize.elm` | Driver with worklist; has `specializeAccessorGlobal` (lines 370-395) - no changes needed |
| `compiler/src/Compiler/Generate/Monomorphize/State.elm` | Has `MonoState`, `WorkItem`, `Substitution` types - no changes needed |
| `compiler/src/Compiler/AST/Monomorphized.elm` | Has `Global = Global IO.Canonical Name \| Accessor Name` - no changes needed |

### Current `TOpt.Call` Handling (Specialize.elm:786-869)

```elm
TOpt.Call region func args canType ->
    let
        ( monoArgs, state1 ) =
            specializeExprs args subst state    -- PROBLEM: Eager specialization
    in
    case func of
        TOpt.VarGlobal funcRegion global funcCanType ->
            -- ... unifyFuncCall, then use monoArgs ...
```

### Current `TOpt.Accessor` Handling (Specialize.elm:932-949)

```elm
TOpt.Accessor region fieldName canType ->
    let
        monoType =
            TypeSubst.applySubst subst canType  -- May have incomplete record type

        accessorGlobal =
            Mono.Accessor fieldName

        ( specId, newRegistry ) =
            Mono.getOrCreateSpecId accessorGlobal monoType Nothing state.registry
        -- ...
```

### Existing `specializeAccessorGlobal` (Monomorphize.elm:370-395)

Already correct - expects `MFunction [ MRecord layout ] fieldType` and builds accessor body with correct field index. No changes needed.

### Existing `extractParamTypes` (TypeSubst.elm:229-239)

Already correct - extracts parameter types from `MFunction` types, handling curried functions. No changes needed.

---

## Implementation Plan

### Step 1: Add `ProcessedArg` Type

**File:** `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm`

**Location:** After imports, before `specializeNode`

**Add:**
```elm
{-| A processed argument that might be pending accessor specialization.
    Accessors need special handling because they must be specialized AFTER
    call-site type unification to receive the fully-resolved record type.
-}
type ProcessedArg
    = ResolvedArg Mono.MonoExpr
    | PendingAccessor A.Region Name Can.Type
```

**Note:** Do NOT export this type - it's internal to `Specialize.elm`.

---

### Step 2: Add `processCallArgs` Function

**File:** `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm`

**Location:** Near `specializeExprs` helper functions

**Add:**
```elm
{-| Process call arguments, deferring accessor specialization.

    Returns:
    - processed args (some are PendingAccessor),
    - the monomorphic arg types for call-site unification,
    - updated MonoState.
-}
processCallArgs :
    List TOpt.Expr
    -> Substitution
    -> MonoState
    -> ( List ProcessedArg, List Mono.MonoType, MonoState )
processCallArgs args subst state =
    List.foldr
        (\arg ( accArgs, accTypes, st ) ->
            case arg of
                TOpt.Accessor region fieldName canType ->
                    let
                        -- Type for unification only; may have incomplete row.
                        -- We will NOT use this to derive the accessor's final MonoType.
                        monoType =
                            TypeSubst.applySubst subst canType
                    in
                    ( PendingAccessor region fieldName canType :: accArgs
                    , monoType :: accTypes
                    , st
                    )

                _ ->
                    let
                        ( monoExpr, st1 ) =
                            specializeExpr arg subst st
                    in
                    ( ResolvedArg monoExpr :: accArgs
                    , Mono.typeOf monoExpr :: accTypes
                    , st1
                    )
        )
        ( [], [], state )
        args
```

**Note:** Do NOT export this function.

---

### Step 3: Add `resolveProcessedArg` Function

**File:** `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm`

**Location:** After `processCallArgs`

**Add:**
```elm
{-| Resolve a single processed argument.

    For PendingAccessor, derives the accessor's MonoType from the expected
    parameter type (which must be a record), NOT from the accessor's canonical type.
-}
resolveProcessedArg :
    ProcessedArg
    -> Maybe Mono.MonoType
    -> Substitution
    -> MonoState
    -> ( Mono.MonoExpr, MonoState )
resolveProcessedArg processedArg maybeParamType subst state =
    case processedArg of
        ResolvedArg monoExpr ->
            ( monoExpr, state )

        PendingAccessor region fieldName _canType ->
            case maybeParamType of
                Just (Mono.MRecord layout) ->
                    -- Derive accessor's MonoType from the full record layout
                    let
                        maybeFieldInfo =
                            List.filter (\f -> f.name == fieldName) layout.fields
                                |> List.head

                        fieldType =
                            case maybeFieldInfo of
                                Just fi ->
                                    fi.monoType

                                Nothing ->
                                    Utils.Crash.crash
                                        "Specialize"
                                        "resolveProcessedArg"
                                        ("Field " ++ fieldName ++ " not found in record layout. This is a compiler bug.")

                        recordType =
                            Mono.MRecord layout

                        accessorMonoType =
                            Mono.MFunction [ recordType ] fieldType

                        accessorGlobal =
                            Mono.Accessor fieldName

                        ( specId, newRegistry ) =
                            Mono.getOrCreateSpecId accessorGlobal accessorMonoType Nothing state.registry

                        newState =
                            { state
                                | registry = newRegistry
                                , worklist = SpecializeGlobal accessorGlobal accessorMonoType Nothing :: state.worklist
                            }
                    in
                    ( Mono.MonoVarGlobal region specId accessorMonoType, newState )

                _ ->
                    Utils.Crash.crash
                        "Specialize"
                        "resolveProcessedArg"
                        "Accessor argument did not receive a record parameter type after monomorphization. This is a compiler bug."
```

**Note:** Do NOT export this function.

---

### Step 4: Add `resolveProcessedArgs` Function

**File:** `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm`

**Location:** After `resolveProcessedArg`

**Add:**
```elm
{-| Resolve a list of processed arguments using the callee's parameter types.
-}
resolveProcessedArgs :
    List ProcessedArg
    -> List Mono.MonoType
    -> Substitution
    -> MonoState
    -> ( List Mono.MonoExpr, MonoState )
resolveProcessedArgs processedArgs paramTypes subst state =
    let
        step processedArg ( acc, st, remainingParams ) =
            let
                ( maybeParam, rest ) =
                    case remainingParams of
                        p :: ps ->
                            ( Just p, ps )

                        [] ->
                            ( Nothing, [] )

                ( monoExpr, st1 ) =
                    resolveProcessedArg processedArg maybeParam subst st
            in
            ( monoExpr :: acc, st1, rest )

        ( revArgs, finalState, _ ) =
            List.foldl step ( [], state, paramTypes ) processedArgs
    in
    ( List.reverse revArgs, finalState )
```

**Note:** Do NOT export this function.

---

### Step 5: Modify `TOpt.Call` Handling

**File:** `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm`

**Location:** Lines 786-869 (the `TOpt.Call` branch in `specializeExpr`)

**Replace the entire `TOpt.Call` branch with:**

```elm
TOpt.Call region func args canType ->
    let
        ( processedArgs, argTypes, state1 ) =
            processCallArgs args subst state
    in
    case func of
        TOpt.VarGlobal funcRegion global funcCanType ->
            let
                callSubst =
                    TypeSubst.unifyFuncCall funcCanType argTypes canType subst

                funcMonoType =
                    TypeSubst.applySubst callSubst funcCanType

                paramTypes =
                    TypeSubst.extractParamTypes funcMonoType

                ( monoArgs, state2 ) =
                    resolveProcessedArgs processedArgs paramTypes callSubst state1

                resultMonoType =
                    TypeSubst.applySubst callSubst canType

                monoGlobal =
                    toptGlobalToMono global

                ( specId, newRegistry ) =
                    Mono.getOrCreateSpecId monoGlobal funcMonoType Nothing state2.registry

                newState =
                    { state2
                        | registry = newRegistry
                        , worklist = SpecializeGlobal monoGlobal funcMonoType Nothing :: state2.worklist
                    }

                monoFunc =
                    Mono.MonoVarGlobal funcRegion specId funcMonoType
            in
            ( Mono.MonoCall region monoFunc monoArgs resultMonoType, newState )

        TOpt.VarKernel funcRegion home name funcCanType ->
            let
                callSubst =
                    TypeSubst.unifyFuncCall funcCanType argTypes canType subst

                funcMonoType =
                    deriveKernelAbiType ( home, name ) funcCanType callSubst

                paramTypes =
                    TypeSubst.extractParamTypes funcMonoType

                ( monoArgs, state2 ) =
                    resolveProcessedArgs processedArgs paramTypes callSubst state1

                resultMonoType =
                    TypeSubst.applySubst callSubst canType

                monoFunc =
                    Mono.MonoVarKernel funcRegion home name funcMonoType
            in
            ( Mono.MonoCall region monoFunc monoArgs resultMonoType, state2 )

        TOpt.VarDebug funcRegion name _ _ funcCanType ->
            let
                callSubst =
                    TypeSubst.unifyFuncCall funcCanType argTypes canType subst

                funcMonoType =
                    deriveKernelAbiType ( "Debug", name ) funcCanType callSubst

                paramTypes =
                    TypeSubst.extractParamTypes funcMonoType

                ( monoArgs, state2 ) =
                    resolveProcessedArgs processedArgs paramTypes callSubst state1

                resultMonoType =
                    TypeSubst.applySubst callSubst canType

                monoFunc =
                    Mono.MonoVarKernel funcRegion "Debug" name funcMonoType
            in
            ( Mono.MonoCall region monoFunc monoArgs resultMonoType, state2 )

        _ ->
            -- Fallback: locally-bound higher-order function
            -- Specialize the function expression first, then use its type
            -- to resolve any pending accessor arguments.
            let
                ( monoFunc, state2 ) =
                    specializeExpr func subst state1

                funcMonoType =
                    Mono.typeOf monoFunc

                paramTypes =
                    TypeSubst.extractParamTypes funcMonoType

                ( monoArgs, state3 ) =
                    resolveProcessedArgs processedArgs paramTypes subst state2

                resultMonoType =
                    TypeSubst.applySubst subst canType
            in
            ( Mono.MonoCall region monoFunc monoArgs resultMonoType, state3 )
```

---

### Step 6: Add Invariant Comment to Standalone `TOpt.Accessor`

**File:** `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm`

**Location:** Lines 932-949 (the `TOpt.Accessor` branch in `specializeExpr`)

**Update to add comment:**

```elm
TOpt.Accessor region fieldName canType ->
    -- NOTE: This handles standalone accessor expressions (not passed as arguments).
    -- The MonoType derived here may have an incomplete record layout if the
    -- accessor's row variable is not yet bound in the substitution.
    --
    -- INVARIANT: Any accessor that is actually *invoked* at runtime must be
    -- specialized via the virtual-global mechanism (Mono.Accessor + worklist),
    -- which happens in resolveProcessedArg when the accessor is passed as an
    -- argument to a function call. The virtual-global path derives the accessor's
    -- MonoType from the fully-resolved parameter type, ensuring correct field indices.
    --
    -- A standalone accessor with incomplete type is only acceptable if it never
    -- participates in layout-dependent operations (e.g., dead code or debug output).
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

---

## Design Decisions

### Q1: Fallback branch for locally-bound HOFs

**Decision:** Support deferred accessors in the fallback `_` branch.

**Rationale:** Code like `(\f -> List.map f people) .name` should behave identically to `List.map .name people`. The fallback path can derive parameter types from the specialized function expression's `MonoType` using `extractParamTypes`.

### Q2: Standalone accessor with incomplete type

**Decision:** Leave as-is with documented invariant.

**Rationale:** The bug only manifests when an accessor's layout is used for indexing at runtime. All call-site uses go through the deferred virtual-global path. Standalone accessors that aren't invoked don't trigger layout operations.

### Q3: Error handling in `resolveProcessedArg`

**Decision:** Crash with descriptive "compiler bug" message.

**Rationale:** If we reach monomorphization and see an accessor argument whose parameter type isn't a record, something has gone wrong in earlier phases. This is not recoverable; falling back to old behavior would reintroduce the bug.

### Q4: Exports from `Specialize.elm`

**Decision:** Keep `ProcessedArg`, `processCallArgs`, `resolveProcessedArg`, `resolveProcessedArgs` internal (not exported).

**Rationale:** These are implementation details of `TOpt.Call` specialization. Exposing them increases coupling for no gain.

---

## Testing Strategy

### Unit Test Cases

1. **Basic accessor as HOF argument:**
   ```elm
   people = [ { name = "Alice", age = 30 } ]
   List.map .name people
   -- Should produce: ["Alice"]
   ```

2. **Accessor with multiple record fields:**
   ```elm
   items = [ { x = 1, y = 2, z = 3 } ]
   List.map .y items
   -- Should produce: [2] with correct field index
   ```

3. **Accessor through locally-bound HOF:**
   ```elm
   applyToList f xs = List.map f xs
   people = [ { name = "Bob", age = 25 } ]
   applyToList .name people
   -- Should produce: ["Bob"]
   ```

4. **Multiple accessors in same call:**
   ```elm
   List.map2 (\r1 r2 -> ( .name r1, .age r2 )) list1 list2
   ```

5. **Nested HOF with accessor:**
   ```elm
   List.map (List.map .field) nestedList
   ```

### Verification Steps

1. Build compiler: `cd compiler && npm run build`
2. Run existing test suite to ensure no regressions
3. Create test file with above cases and verify MLIR output has correct field indices
4. Inspect generated `MonoNode` for accessor specializations to confirm `MRecord` layouts match actual record types

---

## Files Changed Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm` | Modified | Add `ProcessedArg` type, `processCallArgs`, `resolveProcessedArg`, `resolveProcessedArgs`; rewrite `TOpt.Call` handling; add invariant comment to `TOpt.Accessor` |

**No changes to:**
- `TypeSubst.elm` (already has `extractParamTypes`)
- `Monomorphize.elm` (already has `specializeAccessorGlobal`)
- `State.elm`
- `Monomorphized.elm`
