# Move "Ensure Top-Level Callables Are Closures" into MonoGlobalOptimize

## Goal

Ensure any function-typed top-level value or port (including bare `MonoVarKernel` and `MonoVarGlobal`) is a `MonoClosure` **before** the staging pass runs. This prevents MLIR codegen errors like `'eco.papCreate' op could not resolve function symbol 'Elm_Kernel_Basics_mul'`.

## Invariants

After GlobalOpt:

1. No `MonoDefine` or port node has a function-typed expression that is a bare `MonoVarKernel` or `MonoVarGlobal`; such values are always wrapped in `MonoClosure` whose body is a `MonoCall` to the kernel/global.
2. Kernels remain `FlattenedExternal` at call sites (staging unchanged).
3. MLIR codegen: `eco.papCreate` always points to wrapper lambdas, not directly to `Elm_Kernel_*` symbols.

## Current State Analysis

**Pipeline** (`globalOptimize` at line 94):
```
Phase 0: MonoInlineSimplify.optimize
Phase 1+2: Staging.analyzeAndSolveStaging (ProducerInfo -> GraphBuilder -> Solver -> Rewriter)
Phase 3: Staging.validateClosureStaging
Phase 4: annotateCallStaging
```

**Key existing code**:
- `ensureCallableForNode` (line 738) — already exists, handles `MonoVarGlobal`, `MonoVarKernel`, other function-typed exprs. Currently **unused** in the active pipeline.
- `GlobalCtx`, `initGlobalCtx`, `specHome`, `freshLambdaId` — all exist and work correctly.
- `normalizeCaseIfAbi` / `rewriteNodeForAbi` — dead code, not wired into pipeline. Leave as-is.

**Staging Rewriter** (`Rewriter.elm`):
- `rewriteNode` (line 93) handles `MonoDefine` by calling `rewriteExpr` only — **no ensureCallable hack present**.
- Ports fall through to catch-all `_ ->`. Leave alone for now.

## Plan

### Step 1: Add `wrapNodeCallables` to `MonoGlobalOptimize.elm`

Add near `rewriteNodeForAbi` (around line 1190). Wraps only function-typed Define/Port nodes.

**File**: `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

```elm
wrapNodeCallables :
    IO.Canonical
    -> Mono.MonoNode
    -> GlobalCtx
    -> ( Mono.MonoNode, GlobalCtx )
wrapNodeCallables home node ctx =
    case node of
        Mono.MonoDefine expr tipe ->
            let
                ( callableExpr, ctx1 ) =
                    ensureCallableForNode home expr tipe ctx
            in
            ( Mono.MonoDefine callableExpr tipe, ctx1 )

        Mono.MonoPortIncoming expr tipe ->
            let
                ( callableExpr, ctx1 ) =
                    ensureCallableForNode home expr tipe ctx
            in
            ( Mono.MonoPortIncoming callableExpr tipe, ctx1 )

        Mono.MonoPortOutgoing expr tipe ->
            let
                ( callableExpr, ctx1 ) =
                    ensureCallableForNode home expr tipe ctx
            in
            ( Mono.MonoPortOutgoing callableExpr tipe, ctx1 )

        Mono.MonoTailFunc params body tipe ->
            ( Mono.MonoTailFunc params body tipe, ctx )

        Mono.MonoCycle defs tipe ->
            ( Mono.MonoCycle defs tipe, ctx )

        Mono.MonoCtor shape tipe ->
            ( Mono.MonoCtor shape tipe, ctx )

        Mono.MonoEnum tag tipe ->
            ( Mono.MonoEnum tag tipe, ctx )

        Mono.MonoExtern tipe ->
            ( Mono.MonoExtern tipe, ctx )
```

**Notes**:
- Keeps the node's declared `tipe` unchanged. `ensureCallableForNode` adjusts the expression's internal function type (e.g., kernel ABI flattening) but the node type stays as the monomorphic Elm type from Specialize.
- TailFuncs already have explicit params/bodies. Cycles, ctors, enums, externs don't need wrapping.

### Step 2: Add `wrapTopLevelCallables` to `MonoGlobalOptimize.elm`

Graph-level walker using the `Dict.foldl compare` pattern from `normalizeCaseIfAbi`.

**File**: `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

```elm
wrapTopLevelCallables : Mono.MonoGraph -> Mono.MonoGraph
wrapTopLevelCallables (Mono.MonoGraph record0) =
    let
        ctx0 =
            initGlobalCtx (Mono.MonoGraph record0)

        ( newNodes, _ ) =
            Dict.foldl compare
                (\specId node ( accNodes, accCtx ) ->
                    let
                        home =
                            specHome accCtx.registry specId

                        ( newNode, accCtx1 ) =
                            wrapNodeCallables home node accCtx
                    in
                    ( Dict.insert identity specId newNode accNodes, accCtx1 )
                )
                ( Dict.empty, ctx0 )
                record0.nodes
    in
    Mono.MonoGraph { record0 | nodes = newNodes }
```

**Notes**:
- Uses `specHome` for per-node home (not the Rewriter's synthetic `("eco","internal") "GlobalOpt"`).
- Structurally identical to `normalizeCaseIfAbi` pattern.

### Step 3: Wire into `globalOptimize`

Modify `globalOptimize` (line 94) to insert `wrapTopLevelCallables` between Phase 0 and Phase 1+2.

**Before**:
```elm
        ( graph0a, _ ) =
            MonoInlineSimplify.optimize typeEnv graph0

        ( _, graph1 ) =
            Staging.analyzeAndSolveStaging typeEnv graph0a
```

**After**:
```elm
        ( graph0a, _ ) =
            MonoInlineSimplify.optimize typeEnv graph0

        -- Phase 0.5: Wrap top-level function-typed values in closures
        -- (alias wrappers for globals/kernels, general closures for other exprs).
        graph0b =
            wrapTopLevelCallables graph0a

        ( _, graph1 ) =
            Staging.analyzeAndSolveStaging typeEnv graph0b
```

**Why before staging**: Bare `MonoVarKernel`/`MonoVarGlobal` references have no segmentation info and confuse staging analysis. The staging producer graph should only see closures or tail-funcs/`MonoExtern`.

### Step 4: Update documentation

**File**: `design_docs/theory/pass_global_optimization_theory.md`

Update the phase listing (line 44) to include Phase 0.5 and note that `ensureCallableForNode` is called there (not in Phase 2).

**File**: `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

Update module doc (lines 3-18) to add a bullet:
- "Ensures top-level function-typed values (globals/ports) are represented as closures before staging"

## Sanity Checks

1. **Build**: `cmake --build build`
2. **E2E tests**: `cmake --build build --target check`
3. **Frontend tests**: `cd compiler && npx elm-test-rs --fuzz 1`
4. **Grep**: `rg "wrapTopLevelCallables" compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm` → definition + call site
