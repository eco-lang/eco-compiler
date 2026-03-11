# MErased Dead-Value Expression Erasure & Remaining Gaps

## Status: Partially Implemented

Most of the MErased infrastructure is already in place. This plan covers the **remaining gap**: expression-level type erasure inside patched nodes, plus a verification pass to confirm all other pieces are complete and correct.

## Background

The MErased feature replaces unconstrained `MVar _ CEcoValue` type variables with `MErased` in dead-value specializations (specs whose value is never referenced via `MonoVarGlobal`). This prevents false MONO_021 violations while keeping the cycle bug (#7) visible.

### What's Already Done

1. **`MErased` variant** in `MonoType` (`Monomorphized.elm:209`)
2. **`eraseTypeVarsToErased`** helper (`Monomorphized.elm:299-340`) - recursively replaces all `MVar` with `MErased`
3. **`toComparableMonoType`** handles `MErased` (`Monomorphized.elm:894`)
4. **`monoTypeToDebugString`** handles `MErased` (`Monomorphized.elm:671`)
5. **`nodeHasEffects`** effect detection (`Monomorphize.elm:510-541`) - checks for `Debug.*` kernels
6. **`specHasEffects` / `specValueUsed`** as `BitSet` fields in `MonoState` (`State.elm:53-54`) and `MonoGraph` record
7. **`processWorklist`** populates both bitsets during specialization (`Monomorphize.elm:253-379`)
8. **`patchNodeTypesToErased`** patches node-level types for `MonoDefine`/`MonoTailFunc` (`Monomorphize.elm:556-570`)
9. **`monomorphizeFromEntry`** applies patching to non-value-used specs, rebuilds registry (`Monomorphize.elm:123-194`)
10. **Prune** passes through `specHasEffects`/`specValueUsed` without modification (`Prune.elm`)
11. **MLIR codegen** crashes on `MErased` in `monoTypeToAbi`, `monoTypeToOperand`, `TypeTable.processType`
12. **MONO_021 test** (`NoCEcoValueInUserFunctions.elm`) already flags `MErased` via `collectCEcoValueVars`
13. **`invariants.csv`** MONO_021 text already mentions MErased
14. **All other pattern matches** on `MonoType` across the codebase handle `MErased` (Context.elm, GraphBuilder.elm, Specialize.elm, MonoTypeShape.elm, etc.)

### What's Missing

**The single remaining gap**: `patchNodeTypesToErased` only erases **node-level** types (the `MonoType` attached to `MonoDefine`/`MonoTailFunc`), but does **NOT** erase types inside the node's expression tree. This means:

- Closure parameter types inside the expression tree still have `MVar _ CEcoValue`
- Local variable types (`MonoVarLocal`) still have `MVar _ CEcoValue`
- `MonoCall` result types, `MonoLet` types, `MonoTailDef` parameter types, etc. are untouched

This is the gap that can cause MONO_021 violations on closure/tail-def parameter types inside dead-value specs that happen to survive into the reachable graph.

---

## Implementation Plan

### Step 1: Add `eraseExprTypeVars` helper

**File:** `compiler/src/Compiler/Monomorphize/Monomorphize.elm`

Add a helper that uses `MonoTraverse.mapExpr` to rewrite all `MonoType` annotations within an expression tree, applying `Mono.eraseTypeVarsToErased` to each type.

The approach: use `Traverse.mapExpr` with a function that pattern-matches each expression variant and replaces its type annotation. Since `mapExprChildren` only recurses into child expressions (not types), we need a top-level mapper that:
1. First recurses into children (via `mapExprChildren`)
2. Then rewrites the type annotation on the current node

Concretely:

```elm
eraseExprTypeVars : Mono.MonoExpr -> Mono.MonoExpr
eraseExprTypeVars =
    Traverse.mapExpr eraseOneExprType


eraseOneExprType : Mono.MonoExpr -> Mono.MonoExpr
eraseOneExprType expr =
    case expr of
        Mono.MonoLiteral lit t ->
            Mono.MonoLiteral lit (Mono.eraseTypeVarsToErased t)

        Mono.MonoVarLocal name t ->
            Mono.MonoVarLocal name (Mono.eraseTypeVarsToErased t)

        Mono.MonoVarGlobal region specId t ->
            Mono.MonoVarGlobal region specId (Mono.eraseTypeVarsToErased t)

        Mono.MonoVarKernel region home name t ->
            Mono.MonoVarKernel region home name (Mono.eraseTypeVarsToErased t)

        Mono.MonoList region items t ->
            Mono.MonoList region items (Mono.eraseTypeVarsToErased t)

        Mono.MonoClosure info body t ->
            let
                newParams =
                    List.map (\( n, pt ) -> ( n, Mono.eraseTypeVarsToErased pt )) info.params

                newInfo =
                    { info | params = newParams }
            in
            Mono.MonoClosure newInfo body (Mono.eraseTypeVarsToErased t)

        Mono.MonoCall region func args t callInfo ->
            Mono.MonoCall region func args (Mono.eraseTypeVarsToErased t) callInfo

        Mono.MonoTailCall name args t ->
            Mono.MonoTailCall name args (Mono.eraseTypeVarsToErased t)

        Mono.MonoIf branches elseExpr t ->
            Mono.MonoIf branches elseExpr (Mono.eraseTypeVarsToErased t)

        Mono.MonoLet def body t ->
            let
                newDef =
                    case def of
                        Mono.MonoDef name bound ->
                            Mono.MonoDef name bound

                        Mono.MonoTailDef name params bound ->
                            Mono.MonoTailDef name
                                (List.map (\( n, pt ) -> ( n, Mono.eraseTypeVarsToErased pt )) params)
                                bound
            in
            Mono.MonoLet newDef body (Mono.eraseTypeVarsToErased t)

        Mono.MonoDestruct destr inner t ->
            Mono.MonoDestruct destr inner (Mono.eraseTypeVarsToErased t)

        Mono.MonoCase x y decider jumps t ->
            Mono.MonoCase x y decider jumps (Mono.eraseTypeVarsToErased t)

        Mono.MonoRecordCreate fields t ->
            Mono.MonoRecordCreate fields (Mono.eraseTypeVarsToErased t)

        Mono.MonoRecordAccess inner field t ->
            Mono.MonoRecordAccess inner field (Mono.eraseTypeVarsToErased t)

        Mono.MonoRecordUpdate record updates t ->
            Mono.MonoRecordUpdate record updates (Mono.eraseTypeVarsToErased t)

        Mono.MonoTupleCreate region elems t ->
            Mono.MonoTupleCreate region elems (Mono.eraseTypeVarsToErased t)

        Mono.MonoUnit ->
            Mono.MonoUnit
```

**Key design choice**: `mapExpr` calls the mapper *after* recursing into children, so child expressions are already processed. We only need to handle the type annotation at each level. The child expression references (items, func, args, body, etc.) are already rewritten by the recursive `mapExpr` call, so we leave them as-is in the mapper.

**Note on `MonoDestructor`**: The `MonoDestructor` type inside `MonoDestruct` also carries `MonoType` annotations (on `MonoPath` nodes like `MonoIndex`, `MonoField`, `MonoUnbox`, `MonoRoot`). These should also be erased. Add a helper:

```elm
eraseDestructorTypes : Mono.MonoDestructor -> Mono.MonoDestructor
eraseDestructorTypes (Mono.MonoDestructor name path pathType) =
    Mono.MonoDestructor name (erasePathTypes path) (Mono.eraseTypeVarsToErased pathType)

erasePathTypes : Mono.MonoPath -> Mono.MonoPath
erasePathTypes path =
    case path of
        Mono.MonoIndex idx kind t inner ->
            Mono.MonoIndex idx kind (Mono.eraseTypeVarsToErased t) (erasePathTypes inner)
        Mono.MonoField name t inner ->
            Mono.MonoField name (Mono.eraseTypeVarsToErased t) (erasePathTypes inner)
        Mono.MonoUnbox t inner ->
            Mono.MonoUnbox (Mono.eraseTypeVarsToErased t) (erasePathTypes inner)
        Mono.MonoRoot name t ->
            Mono.MonoRoot name (Mono.eraseTypeVarsToErased t)
```

And in `eraseOneExprType`, the `MonoDestruct` case becomes:
```elm
        Mono.MonoDestruct destr inner t ->
            Mono.MonoDestruct (eraseDestructorTypes destr) inner (Mono.eraseTypeVarsToErased t)
```

### Step 2: Update `patchNodeTypesToErased` to also erase expression types

**File:** `compiler/src/Compiler/Monomorphize/Monomorphize.elm`

Modify `patchNodeTypesToErased` to apply `eraseExprTypeVars` to the expression inside `MonoDefine` and `MonoTailFunc`:

```elm
patchNodeTypesToErased node =
    case node of
        Mono.MonoDefine expr t ->
            Mono.MonoDefine
                (eraseExprTypeVars expr)
                (Mono.eraseTypeVarsToErased t)

        Mono.MonoTailFunc params expr t ->
            Mono.MonoTailFunc
                (List.map (\( n, ty ) -> ( n, Mono.eraseTypeVarsToErased ty )) params)
                (eraseExprTypeVars expr)
                (Mono.eraseTypeVarsToErased t)

        -- Do NOT patch: cycles (preserve MONO_021 visibility), ports (ABI obligations),
        -- externs/managers (kernel ABI), ctors/enums (no MVars in practice)
        _ ->
            node
```

This is the **only behavioral change** — adding `eraseExprTypeVars expr` to both arms.

### Step 3: Verify — no other changes needed

Confirm that the following are already correct (no code changes):

- **`Prune.pruneUnreachableSpecs`**: Already compatible. Passes through bitsets, rebuilds registry from patched nodes. No change needed.
- **MLIR codegen** (`Types.elm`): Already crashes on `MErased` in `monoTypeToAbi` and `monoTypeToOperand`. No change needed.
- **MONO_021 test** (`NoCEcoValueInUserFunctions.elm`): Already flags `MErased` as a violation in `collectCEcoValueVars`. No change needed.
- **`invariants.csv`**: MONO_021 already mentions MErased. No change needed.
- **`toComparableMonoType`**: Already handles `MErased`. No change needed.
- **All downstream pattern matches on `MonoType`**: Already handle `MErased`. No change needed.

---

## Testing

1. **Elm frontend tests**: `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1` — verifies MONO_021 passes with the expression-level erasure.
2. **E2E tests**: `cmake --build build --target check` — verifies no MErased leaks into codegen for reachable specs.

## Files Changed

| File | Change |
|------|--------|
| `compiler/src/Compiler/Monomorphize/Monomorphize.elm` | Add `eraseExprTypeVars`, `eraseOneExprType`, `eraseDestructorTypes`, `erasePathTypes`; update `patchNodeTypesToErased` to call `eraseExprTypeVars` |

## Risk Assessment

- **Low risk**: The erasure only applies to dead-value specs (not value-used), and only to `MonoDefine`/`MonoTailFunc` (not cycles/ports). If `MErased` leaks into a reachable spec, MONO_021 and MLIR codegen will catch it.
- **No semantic change**: Pruning semantics unchanged. Effect tracking unchanged. Call graph unchanged.
