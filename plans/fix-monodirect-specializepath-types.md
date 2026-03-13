# Plan: Fix MonoDirect specializePath to Compute Concrete Types

## Problem

MonoDirect's `specializePath` in `compiler/src/Compiler/MonoDirect/Specialize.elm:918-953` uses `Mono.MErased` for all path type annotations (rootType, indexType) instead of computing concrete types. This causes 68 "produces same MonoGraph" test failures and contributes to the 10 "has no CEcoValue in user functions" failures.

The original `Monomorphize/Specialize.elm:2734-2818` computes types bottom-up:
- `MonoRoot` looks up the variable's type from `VarEnv`
- `MonoIndex` derives the projected type from the container via `computeIndexProjectionType`
- `MonoField` extracts the field type from `MRecord`
- `MonoUnbox` resolves the wrapped type via `computeUnboxResultType`
- `MonoIndex (ArrayIndex)` extracts the element type from `MCustom _ "Array" [elemType]`

MonoDirect already has the VarEnv infrastructure (`State.lookupVar`) and the `globalTypeEnv` in state. It just doesn't use them in `specializePath`.

## Design

### Step 1: Thread VarEnv and GlobalTypeEnv into specializePath

Change the signature from:
```elm
specializePath : LocalView -> TOpt.Path -> Mono.MonoPath
```
to:
```elm
specializePath : LocalView -> VarEnv -> TypeEnv.GlobalTypeEnv -> TOpt.Path -> Mono.MonoPath
```

The `VarEnv` is already on `state.varEnv` and `GlobalTypeEnv` is on `state.globalTypeEnv` at every call site. Both `specializeDestructor` and `specializeDestructorPathType` will need to receive and forward these.

### Step 2: Implement bottom-up type computation in specializePath

Replace the MErased placeholders with concrete type computation. The algorithm is identical to the original `Monomorphize/Specialize.elm:2734-2818`:

```elm
specializePath : LocalView -> VarEnv -> TypeEnv.GlobalTypeEnv -> TOpt.Path -> Mono.MonoPath
specializePath view varEnv globalTypeEnv path =
    case path of
        TOpt.Root name ->
            let
                rootType =
                    case State.lookupVar name varEnv of
                        Just ty -> ty
                        Nothing -> Utils.Crash.crash ("MonoDirect.specializePath: Root variable '" ++ name ++ "' not found in VarEnv.")
            in
            Mono.MonoRoot name rootType

        TOpt.Index idx hint inner ->
            let
                monoSubPath = specializePath view varEnv globalTypeEnv inner
                containerType = Mono.getMonoPathType monoSubPath
                resultType = computeIndexProjectionType globalTypeEnv hint (Index.toMachine idx) containerType
            in
            Mono.MonoIndex (Index.toMachine idx) (hintToKind hint) resultType monoSubPath

        TOpt.Field fieldName inner ->
            let
                monoSubPath = specializePath view varEnv globalTypeEnv inner
                recordType = Mono.getMonoPathType monoSubPath
                resultType =
                    case recordType of
                        Mono.MRecord fields ->
                            case Dict.get fieldName fields of
                                Just ft -> ft
                                Nothing -> Utils.Crash.crash ("MonoDirect.specializePath: Field '" ++ fieldName ++ "' not found in record type.")
                        _ ->
                            Utils.Crash.crash ("MonoDirect.specializePath: Expected MRecord for field path, got: " ++ Mono.monoTypeToDebugString recordType)
            in
            Mono.MonoField fieldName resultType monoSubPath

        TOpt.Unbox inner ->
            let
                monoSubPath = specializePath view varEnv globalTypeEnv inner
                containerType = Mono.getMonoPathType monoSubPath
                resultType = computeUnboxResultType globalTypeEnv containerType
            in
            Mono.MonoUnbox resultType monoSubPath

        TOpt.ArrayIndex idx inner ->
            let
                monoSubPath = specializePath view varEnv globalTypeEnv inner
                containerType = Mono.getMonoPathType monoSubPath
                resultType = computeArrayElementType containerType
            in
            Mono.MonoIndex idx (Mono.CustomContainer "") resultType monoSubPath
```

### Step 3: Add helper functions to MonoDirect/Specialize.elm

Copy these helpers from `Monomorphize/Specialize.elm` (they are pure functions with no state dependencies):

1. **`computeIndexProjectionType`** (lines 2823-2848): dispatches on `ContainerHint` to extract element types from `MList`, `MTuple`, or `MCustom` (via `computeCustomFieldType`).

2. **`computeTupleElementType`** (lines 2852-2864): indexes into `MTuple` element list.

3. **`computeCustomFieldType`** (lines 2873-2901): looks up the constructor in `GlobalTypeEnv` via `Analysis.lookupUnion`, builds a type variable substitution from the monomorphized type args, and applies it to the canonical field type. **Requires** `import Compiler.Monomorphize.Analysis as Analysis` and `import Compiler.Monomorphize.TypeSubst as TypeSubst`.

4. **`computeUnboxResultType`** (lines 2918-2947): finds the single field type of a single-constructor custom type via `Analysis.lookupUnion`.

5. **`computeArrayElementType`** (lines 2952-2959): extracts element type from `MCustom _ "Array" [elemType]`.

6. **`findCtorByName`** (lines 2906-2909): helper to find a constructor by name in a union's alternatives.

7. **`hintToKind`** (lines 2964-2977): converts `TOpt.ContainerHint` to `Mono.ContainerKind` (MonoDirect already has this inline in the current `specializePath`, but it should be extracted for clarity).

### Step 4: Update call sites

Three functions call `specializePath`:

1. **`specializeDestructor`** (line 894): Change from `specializePath view path` to `specializePath view state.varEnv state.globalTypeEnv path`. This means `specializeDestructor` needs `state` (or at minimum `varEnv` and `globalTypeEnv`) passed in. Currently it only takes `LocalView` and `TOpt.Destructor`.

   Change signature:
   ```elm
   specializeDestructor : LocalView -> VarEnv -> TypeEnv.GlobalTypeEnv -> TOpt.Destructor -> Mono.MonoDestructor
   ```

2. **`specializeDestructorPathType`** (line 901): Same change. But note — this function is used at `Specialize.elm:413` to compute the type to insert into VarEnv for the destructor binding. After the fix, the destructor path's root type will be looked up from VarEnv, so the binding must already be in VarEnv before the path is specialized. Verify that the current code inserts `dName` with `destructorType` (line 416) before calling `specializeExpr` on the body (line 419), which is correct — the destructor binding type comes from `resolveDestructorType` (solver-based), not from the path.

3. **Callers of `specializeDestructor`/`specializeDestructorPathType`** in `specializeExpr` (line 406, 413): Pass `state.varEnv` and `state.globalTypeEnv`.

### Step 5: Add new imports to MonoDirect/Specialize.elm

```elm
import Compiler.Monomorphize.Analysis as Analysis
import Compiler.Monomorphize.TypeSubst as TypeSubst
import Compiler.AST.TypeEnv as TypeEnv
```

`TypeEnv` is already indirectly available through `State`, but needs a direct import for the `GlobalTypeEnv` type in function signatures.

### Step 6: Alternative — share helpers from Monomorphize/Specialize

Instead of copying the helper functions, consider extracting them into a shared module (e.g., `Compiler.Monomorphize.PathTypes`). This avoids duplication. However, `computeCustomFieldType` and `computeUnboxResultType` use `TypeSubst.applySubst` which is the string-substitution approach. Since MonoDirect is solver-based and avoids TypeSubst, an alternative is to use the solver's `LocalView.monoTypeOf` to resolve type variables in the constructor field types. But for path type computation, using TypeSubst locally is fine — the substitution is built from already-monomorphized type args, not from solver state. The original helpers are pure functions of `(GlobalTypeEnv, MonoType) -> MonoType`.

**Recommendation**: Copy the helpers directly into MonoDirect/Specialize.elm. They are small, pure, and self-contained. Sharing would create a module dependency that complicates the separation between the two monomorphization approaches.

## Files Changed

| File | Change |
|------|--------|
| `compiler/src/Compiler/MonoDirect/Specialize.elm` | Rewrite `specializePath`, add helpers, update `specializeDestructor`/`specializeDestructorPathType` signatures, add imports |

## Estimated Scope

~120 lines of new/changed code in a single file. No architectural changes. No new modules.

## Verification

After implementation, run:
```bash
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1
```

The 68 "produces same MonoGraph" failures involving `destr.path.indexType` and `destr.path.inner.rootType` should resolve. The "accessor in pipeline" failure may partially improve (the spec key for `apR` depends on correct path types propagating through the accessor's record type).

The 10 "has no CEcoValue in user functions" failures are a separate issue (missing `fillUnconstrainedCEcoWithErased` step) and are NOT addressed by this plan.
