# GlobalOpt Accidental Complexity Reduction Plan

## Overview

This plan addresses accidental complexity in the GlobalOpt phase (`compiler/src/Compiler/GlobalOpt/`) by:
1. Consistently using `MonoTraverse` for AST traversal
2. Consolidating phases 1-3 into fewer passes
3. Abstracting case/if branch normalization
4. Layering context types around a shared core
5. Modernizing the inliner to use unified patterns

## Current State

The GlobalOpt phase runs 4 sequential passes (with a 5th disabled):
- Phase 1: `canonicalizeClosureStaging` - pure map over graph
- Phase 2: `normalizeCaseIfAbi` - context-threaded rewrite
- Phase 3: `validateClosureStaging` - pure validation fold
- Phase 4: `annotateCallStaging` - call metadata computation
- Phase 5: `MonoInlineSimplify.optimize` - COMMENTED OUT

Each phase traverses the entire graph independently, with duplicated pattern matching.

---

## Step 1: Refactor `rewriteExprForAbi` to use `traverseExprChildren`

### Files Modified
- `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

### Current Code (lines 726-883)
Manual recursion over ~15 `MonoExpr` variants, threading `GlobalCtx`.

### Design Decision: Keep Case/If ABI Logic Self-Contained

The ABI normalization for `MonoCase` and `MonoIf` is handled by `rewriteCaseForAbi`, `rewriteIfForAbi`, and `rewriteCaseLeavesToAbiGO`. These functions own the traversal over deciders and branches, threading `GlobalCtx` consistently.

**Key constraint**: ABI normalization only happens in these dedicated functions. We must NOT introduce additional ABI logic into a generic traversal callback.

### Target Pattern (Option A: Use `traverseExpr` with delegation)
```elm
rewriteExprForAbi : IO.Canonical -> Mono.MonoExpr -> GlobalCtx -> ( Mono.MonoExpr, GlobalCtx )
rewriteExprForAbi home expr ctx0 =
    Traverse.traverseExpr
        (\ctx e ->
            case e of
                Mono.MonoCase scrutName scrutTypeName decider branches resultType ->
                    -- Delegate to existing ABI handler (owns its own decider/branch traversal)
                    rewriteCaseForAbi home scrutName scrutTypeName decider branches resultType ctx

                Mono.MonoIf branches final resultType ->
                    -- Delegate to existing ABI handler
                    rewriteIfForAbi home branches final resultType ctx

                _ ->
                    ( e, ctx )
        )
        ctx0
        expr
```

### Target Pattern (Option B: Keep specialized structure, use `traverseExprChildren` for non-case/if)
```elm
rewriteExprForAbi : IO.Canonical -> Mono.MonoExpr -> GlobalCtx -> ( Mono.MonoExpr, GlobalCtx )
rewriteExprForAbi home expr ctx =
    case expr of
        -- ABI normalization targets - use existing handlers
        Mono.MonoCase scrutName scrutTypeName decider branches resultType ->
            rewriteCaseForAbi home scrutName scrutTypeName decider branches resultType ctx

        Mono.MonoIf branches final resultType ->
            rewriteIfForAbi home branches final resultType ctx

        -- All other cases: structural recursion via MonoTraverse
        _ ->
            Traverse.traverseExprChildren (rewriteExprForAbi home) ctx expr
```

**Recommendation**: Option B is safer because it completely sidesteps the interaction question between generic traversal and the specialized decider/branch rewriting in `rewriteCaseLeavesToAbiGO`.

### Changes Required
1. Replace manual structural recursion for non-case/if constructors with `traverseExprChildren`
2. Keep `MonoCase` and `MonoIf` handlers calling into existing `rewriteCaseForAbi` / `rewriteIfForAbi`
3. Remove ~130 lines of boilerplate for lists, records, tuples, calls, etc.

### Invariants Preserved
- GOPT_003: Case/if branch ABI normalization still applied at same points
- All subexpressions still visited (children before parent for non-case/if)
- Decider/branch traversal remains self-contained in `rewriteCaseLeavesToAbiGO`

---

## Step 2: Refactor `annotateExprCalls` - Hybrid Approach

### Files Modified
- `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

### Current Code (lines 1430-1526)
Manual recursion computing `CallInfo` for each `MonoCall`, updating `CallEnv` at `MonoLet`.

### Design Decision: Manual Recursion for `MonoLet`

**Problem**: `Traverse.traverseExpr` is bottom-up - it visits children BEFORE calling the callback. For `MonoLet`, we need to update `CallEnv` with the def's binding BEFORE visiting the body, so the body sees the new binding.

```elm
-- MonoTraverse.traverseExprChildren for MonoLet:
MonoLet def body resultType ->
    let
        ( newDef, ctx1 ) = traverseDef f ctx def
        ( newBody, ctx2 ) = f ctx1 body  -- body visited with ctx from def, NOT with updated env
    in
    ( MonoLet newDef newBody resultType, ctx2 )
```

There's no hook to "insert binding into CallEnv" between def and body traversal.

**Solution**: Keep manual recursion for `MonoLet`, use `MonoTraverse` for everything else.

### Target Pattern
```elm
annotateExprCalls : Mono.MonoGraph -> CallEnv -> Mono.MonoExpr -> Mono.MonoExpr
annotateExprCalls graph env expr =
    case expr of
        -- Special case: MonoLet needs manual recursion for correct CallEnv scoping
        Mono.MonoLet def body tipe ->
            let
                ( def1, env1 ) =
                    annotateDefCalls graph env def

                body1 =
                    annotateExprCalls graph env1 body
            in
            Mono.MonoLet def1 body1 tipe

        -- All other cases: use structural helper
        _ ->
            annotateExprCallsStructural graph env expr


annotateExprCallsStructural : Mono.MonoGraph -> CallEnv -> Mono.MonoExpr -> Mono.MonoExpr
annotateExprCallsStructural graph env expr =
    -- For non-MonoLet cases, CallEnv doesn't change, so we can use mapExprChildren
    -- and only do work at MonoCall nodes
    let
        recurse = annotateExprCalls graph env

        annotateCall e =
            case e of
                Mono.MonoCall region func args resultType _ ->
                    let
                        callInfo = computeCallInfo graph env func args resultType
                    in
                    Mono.MonoCall region func args resultType callInfo
                _ ->
                    e
    in
    annotateCall (Traverse.mapExprChildren recurse expr)
```

### Key Insight
For all constructors except `MonoLet`, the `CallEnv` does not change (calls only READ from it). So we can:
1. Use `mapExprChildren` for structural recursion (no context threading needed)
2. Apply the `MonoCall` annotation at each node
3. Handle `MonoLet` specially with its precise env update + body sequencing

### Changes Required
1. Extract `annotateExprCallsStructural` helper using `mapExprChildren`
2. Keep `MonoLet` case with manual recursion and proper env sequencing
3. Delete manual recursion for all other ~12 constructors (~80 lines)

### Invariants Preserved
- CallInfo computed for all MonoCall nodes
- CallEnv updated at let bindings BEFORE body is processed
- Correct scoping: body sees binding from its enclosing let

---

## Step 3: Refactor `MonoInlineSimplify` to use `traverseExpr`

### Files Modified
- `compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm`

### Current Code
- `rewriteExpr` (lines 581-730): Manual recursion for inlining/beta-reduction
- `simplifyLets` (lines 1297-1442): Manual recursion for let simplification
- Helper functions: `rewriteExprs`, `rewriteBranches`, `simplifyLetsBranches`, etc.

### Target Pattern for `rewriteExpr`
```elm
rewriteExpr : RewriteCtx -> MonoExpr -> ( MonoExpr, RewriteCtx )
rewriteExpr ctx0 expr =
    Traverse.traverseExpr
        (\ctx e ->
            case e of
                -- Beta reduction: ((\\x -> body) arg)
                MonoCall region (MonoClosure info closureBody closureType) args resultType _ ->
                    betaReduce ctx region info closureBody args resultType

                -- Direct call inlining
                MonoCall region (MonoVarGlobal varRegion specId funcType) args resultType _ ->
                    let
                        ( maybeInlined, ctx1 ) = tryInlineCall ctx specId args resultType
                    in
                    case maybeInlined of
                        Just inlinedExpr -> rewriteExpr ctx1 inlinedExpr
                        Nothing -> ( e, ctx1 )

                -- Simplify known if conditions
                MonoIf [ ( MonoLiteral (Mono.LBool True) _, thenBranch ) ] _ _ ->
                    ( thenBranch, ctx )

                MonoIf [ ( MonoLiteral (Mono.LBool False) _, _ ) ] final _ ->
                    ( final, ctx )

                _ ->
                    ( e, ctx )
        )
        ctx0
        expr
```

### Target Pattern for `simplifyLets`
```elm
simplifyLets : RewriteCtx -> MonoExpr -> ( MonoExpr, RewriteCtx )
simplifyLets ctx0 expr =
    Traverse.traverseExpr
        (\ctx e ->
            case e of
                MonoLet def body resultType ->
                    let
                        defName = getDefName def
                        defBound = getDefBound def
                        usageCount = countUsages defName body
                    in
                    if usageCount == 0 && isPureExpr defBound then
                        let
                            newMetrics = { ctx.metrics | letEliminations = ctx.metrics.letEliminations + 1 }
                        in
                        ( body, { ctx | metrics = newMetrics } )
                    else
                        ( e, ctx )

                _ ->
                    ( e, ctx )
        )
        ctx0
        expr
```

### Changes Required
1. Replace `rewriteExpr` with `traverseExpr`-based implementation
2. Replace `simplifyLets` with `traverseExpr`-based implementation
3. Delete helper functions: `rewriteExprs`, `rewriteCaptures`, `rewriteBranches`, `rewriteDef`, `rewriteCaseBranches`, `rewriteNamedFields`, `rewriteTailCallArgs`
4. Delete helper functions: `simplifyLetsExprs`, `simplifyLetsCaptures`, `simplifyLetsBranches`, etc.
5. Implement `countUsages` using `Traverse.foldExpr`

### Invariants Preserved
- Beta reduction at immediate closure calls
- Inlining of eligible global calls
- Let elimination for unused pure bindings

---

## Step 4: Use `foldExpr` for analysis functions

### Files Modified
- `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`
- `compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm`

### Current Code
- `validateExprClosures` (lines 1364-1384): Manual recursion
- `countUsages` in MonoInlineSimplify (lines 1588-1632): Manual recursion

### Target Pattern for `validateExprClosures`
```elm
validateExprClosures : Mono.MonoExpr -> ()
validateExprClosures expr =
    Traverse.foldExpr validateClosureParams () expr
```

### Target Pattern for `countUsages`
```elm
countUsages : Name -> MonoExpr -> Int
countUsages targetName expr =
    Traverse.foldExpr
        (\e count ->
            case e of
                MonoVarLocal name _ ->
                    if name == targetName then count + 1 else count
                _ ->
                    count
        )
        0
        expr
```

### Changes Required
1. Replace `validateExprClosures` with `foldExpr` call
2. Replace `countUsages` with `foldExpr` call
3. Replace other analysis functions similarly

---

## Step 5: Consolidate phases 1-3 into a single pass

### Files Modified
- `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

### Current Flow
```
graph0 -> canonicalizeClosureStaging -> graph1
graph1 -> normalizeCaseIfAbi -> graph2
graph2 -> validateClosureStaging -> graph3
```

### Target Flow
```
graph0 -> canonicalizeAndNormalizeAbi -> graph1  (combined pass)
```

### New Combined Function
```elm
canonicalizeAndNormalizeAbi : Mono.MonoGraph -> Mono.MonoGraph
canonicalizeAndNormalizeAbi (Mono.MonoGraph record0) =
    let
        ctx0 = initGlobalCtx (Mono.MonoGraph record0)

        ( newNodes, _ ) =
            Dict.foldl compare
                (\specId node ( accNodes, accCtx ) ->
                    let
                        home = specHome accCtx.registry specId
                        ( newNode, accCtx1 ) = canonicalizeAndRewriteNode home node accCtx
                    in
                    ( Dict.insert identity specId newNode accNodes, accCtx1 )
                )
                ( Dict.empty, ctx0 )
                record0.nodes
    in
    Mono.MonoGraph { record0 | nodes = newNodes }


canonicalizeAndRewriteNode : IO.Canonical -> Mono.MonoNode -> GlobalCtx -> ( Mono.MonoNode, GlobalCtx )
canonicalizeAndRewriteNode home node ctx =
    -- For each node:
    -- 1. Canonicalize closure types (Phase 1 logic)
    -- 2. Apply ABI normalization (Phase 2 logic)
    -- 3. Validate invariants inline (Phase 3 logic)
    ...
```

### Key Insight
The callback to `Traverse.traverseExpr` can do all three operations:
1. At `MonoClosure`: canonicalize type via `flattenTypeToArity`, then validate GOPT_001
2. At `MonoCase`/`MonoIf`: apply ABI normalization, creating new closures that are immediately canonicalized
3. Validation happens inline rather than as separate pass

### Changes Required
1. Create new `canonicalizeAndNormalizeAbi` function
2. Create new `canonicalizeAndRewriteNode` function
3. Move `canonicalizeClosureType` logic into the traversal callback
4. Move `validateClosureParams` logic into the traversal callback (as assertions)
5. Update `globalOptimize` to call single combined function
6. Keep `validateClosureStaging` as optional separate sanity check (can be removed later)

### Invariants Preserved
- GOPT_001: Validated inline during canonicalization
- GOPT_003: ABI normalization applied as before
- Closures created during ABI normalization are immediately canonicalized

---

## Step 6: Abstract case/if branch normalization

### Files Modified
- `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

### Current Code
- `rewriteCaseForAbi` (lines 917-946): Handles MonoCase
- `rewriteIfForAbi` (lines 1116-1199): Handles MonoIf (parallel structure)

### Shared Pattern
Both functions:
1. Collect leaf result types that are functions
2. If none: recurse structurally
3. Otherwise: pick canonical segmentation, build canonical type, wrap non-canonical leaves

### New Abstraction
```elm
type alias LeafRewriter =
    { collectLeafTypes : () -> List Mono.MonoType
    , rewriteLeaf : Mono.MonoType -> List Int -> Mono.MonoExpr -> GlobalCtx -> ( Mono.MonoExpr, GlobalCtx )
    , buildResult : GlobalCtx -> result
    }

normalizeFunctionLeaves :
    IO.Canonical
    -> List Mono.MonoType  -- collected leaf types
    -> (Mono.MonoType -> List Int -> Mono.MonoExpr -> GlobalCtx -> ( Mono.MonoExpr, GlobalCtx ))  -- rewrite leaf
    -> GlobalCtx
    -> ...
```

### Alternative: Simpler Helper
```elm
normalizeLeafToCanonical :
    IO.Canonical
    -> Mono.MonoType  -- canonical type
    -> List Int       -- canonical segmentation
    -> Mono.MonoExpr  -- leaf expression
    -> GlobalCtx
    -> ( Mono.MonoExpr, GlobalCtx )
normalizeLeafToCanonical home canonicalType canonicalSeg leafExpr ctx =
    case Mono.typeOf leafExpr of
        Mono.MFunction _ _ ->
            if Mono.segmentLengths (Mono.typeOf leafExpr) == canonicalSeg then
                rewriteExprForAbi home leafExpr ctx
            else
                buildAbiWrapperGO home canonicalType leafExpr ctx
        _ ->
            rewriteExprForAbi home leafExpr ctx
```

### Changes Required
1. Extract common normalization logic into shared helper
2. Refactor `rewriteCaseForAbi` to use helper
3. Refactor `rewriteIfForAbi` to use helper
4. Delete duplicated leaf-rewriting code

---

## Step 7: Consolidate context types

### Files Modified
- `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`
- `compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm`

### Current Context Types
```elm
-- MonoGlobalOptimize.elm
type alias GlobalCtx =
    { registry : Mono.SpecializationRegistry
    , lambdaCounter : Int
    }

type alias CallEnv =
    { varCallModel : Dict String Name Mono.CallModel
    , varSourceArity : Dict String Name Int
    }

-- MonoInlineSimplify.elm
type alias RewriteCtx =
    { nodes : Dict Int SpecId MonoNode
    , registry : Mono.SpecializationRegistry  -- DUPLICATED
    , callGraph : CallGraph
    , whitelist : InlineWhitelist
    , inlineCountThisFunction : Int
    , varCounter : Int
    , lambdaCounter : Int  -- DUPLICATED
    , metrics : InternalMetrics
    }
```

### Target Structure
```elm
-- Shared core (could be in MonoGlobalOptimize.elm or new module)
type alias OptGlobal =
    { registry : Mono.SpecializationRegistry
    , lambdaCounter : Int
    }

-- MonoGlobalOptimize.elm
type alias GlobalCtx = OptGlobal

type alias CallCtx =
    { opt : OptGlobal
    , env : CallEnv
    }

-- MonoInlineSimplify.elm
type alias RewriteCtx =
    { opt : OptGlobal
    , nodes : Dict Int SpecId MonoNode
    , callGraph : CallGraph
    , whitelist : InlineWhitelist
    , inlineCountThisFunction : Int
    , varCounter : Int
    , metrics : InternalMetrics
    }
```

### Changes Required
1. Define `OptGlobal` type alias
2. Update `GlobalCtx` to equal `OptGlobal`
3. Update `RewriteCtx` to embed `OptGlobal` as `opt` field
4. Update all `freshLambdaId` calls to work with either context type
5. Update all `registry` accesses to go through appropriate path

---

## Step 8: Update `globalOptimize` entry point

### Files Modified
- `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

### Current Code (lines 83-106)
```elm
globalOptimize typeEnv graph0 =
    let
        graph1 = canonicalizeClosureStaging graph0
        graph2 = normalizeCaseIfAbi graph1
        graph3 = validateClosureStaging graph2
        graph4 = annotateCallStaging graph3
        -- ( graph5, _ ) = MonoInlineSimplify.optimize mode typeEnv graph4
    in
    graph4
```

### Target Code
```elm
globalOptimize typeEnv graph0 =
    let
        -- Phase 1: Canonicalize + ABI normalize + validate (combined)
        graph1 = canonicalizeAndNormalizeAbi graph0

        -- Phase 2: Annotate call staging metadata
        graph2 = annotateCallStaging graph1

        -- Phase 3: Inlining and DCE (currently disabled)
        -- ( graph3, _ ) = MonoInlineSimplify.optimize typeEnv graph2
    in
    graph2
```

---

## Implementation Order

### Phase A: Traversal Refactoring (Low Risk)
1. Step 1: Refactor `rewriteExprForAbi`
2. Step 2: Refactor `annotateExprCalls`
3. Step 4: Use `foldExpr` for analysis
4. Run tests after each step

### Phase B: Inliner Modernization (Medium Risk, Isolated)
5. Step 3: Refactor `rewriteExpr` and `simplifyLets`
6. Run inliner unit tests

### Phase C: Phase Consolidation (Medium Risk)
7. Step 5: Consolidate phases 1-3
8. Step 6: Abstract case/if normalization
9. Step 8: Update entry point
10. Full test suite

### Phase D: Context Layering (Low Risk)
11. Step 7: Consolidate context types
12. Full test suite

---

## Testing Strategy

### Existing Tests
- `npx elm-test-rs --fuzz 1` in `compiler/` - frontend tests
- `cmake --build build --target check` - E2E tests

### Specific Test Focus
- GOPT invariant tests (if they exist)
- Codegen tests for closures and staging
- Any tests that exercise case/if with function-typed branches

### Regression Detection
Each step should:
1. Compile successfully
2. Pass all existing tests
3. Produce identical MLIR output for test cases (can sample-check)

---

## Questions and Open Issues

### Q1: `traverseExpr` Application Order
**Question**: `Traverse.traverseExpr` applies the callback bottom-up (children first). Is this correct for all uses?

**Analysis**:
- `rewriteExprForAbi`: Needs bottom-up (children normalized before parent case/if examined)
- `annotateExprCalls`: Needs bottom-up (func/args annotated before computing CallInfo)
- `simplifyLets`: Needs bottom-up (inner lets simplified before outer)

**Conclusion**: Bottom-up is correct for all current uses.

### Q2: Decider Traversal in Combined Pass ✅ RESOLVED
**Question**: `rewriteCaseForAbi` calls `rewriteDeciderForAbi` which has its own recursion. How does this interact with the combined pass?

**Resolution**: Keep case/if ABI logic self-contained. `rewriteCaseForAbi` / `rewriteIfForAbi` / `rewriteCaseLeavesToAbiGO` own all decider + branch rewriting. The combined pass's callback for `MonoCase` and `MonoIf` delegates to these existing helpers rather than trying to inline their logic.

**Approach chosen** (Step 1, Option B): Keep the current specialized structure for case/if, but use `traverseExprChildren` to remove boilerplate for other constructors. This completely sidesteps the interaction question.

**Key invariant**: ABI normalization ONLY happens in the dedicated functions (`rewriteCaseForAbi`, `rewriteIfForAbi`, `rewriteCaseLeavesToAbiGO`, `buildAbiWrapperGO`, `ensureCallableForNode`). No additional ABI logic in generic traversal callbacks.

### Q3: Fresh Lambda ID Generation Order
**Question**: When combining phases, fresh lambda IDs are generated during ABI wrapper creation. Does the order matter?

**Analysis**: Lambda IDs just need to be unique within the compilation unit. The current `lambdaCounter` threading ensures uniqueness.

**Conclusion**: Order doesn't matter as long as counter is properly threaded.

### Q4: Validation Timing in Combined Pass
**Question**: Currently Phase 3 validates after all transformations. If we validate inline during Phase 1-2, do we catch all violations?

**Analysis**:
- Closures from input should be validated after canonicalization
- Closures created during ABI normalization should be validated immediately after creation
- Inline validation covers both cases

**Conclusion**: Inline validation is sufficient. Optional separate validation pass can remain for debugging.

### Q5: `CallEnv` Scope in Annotation Pass ✅ RESOLVED
**Question**: `CallEnv` is updated at `MonoLet` definitions. With `traverseExpr`, is the scope handled correctly?

**Resolution**: Hybrid approach - keep manual recursion for `MonoLet`, use `MonoTraverse` for everything else.

**Rationale**: `traverseExpr` is bottom-up, so by the time the callback sees `MonoLet`, the body has already been processed with the OLD context. There's no hook to insert a binding into `CallEnv` between def and body traversal.

**Approach**:
1. Handle `MonoLet` manually: call `annotateDefCalls`, get updated `env1`, then recurse on body with `env1`
2. For all other constructors: use `mapExprChildren` since `CallEnv` doesn't change (calls only read from it)
3. Apply `MonoCall` annotation at each node

This keeps the ordering requirement exactly as today while deleting ~80 lines of repeated structural recursion.

### Q6: Inliner Re-enablement Path ✅ RESOLVED
**Question**: When should the inliner be re-enabled?

**Resolution**: Inliner remains disabled during this refactoring. The code is kept and modernized (Step 3), but the call in `globalOptimize` stays commented out. Re-enablement is a separate future task.

### Q7: Performance Impact
**Question**: Does using generic traversal have performance overhead vs. manual recursion?

**Analysis**:
- `Traverse.traverseExpr` does one allocation per node (tuple for context threading)
- Manual recursion does the same
- No significant difference expected

**Assumption**: Performance is acceptable. Can profile if needed.

---

## Assumptions

1. **No semantic changes**: All refactoring is purely structural; behavior must be identical.

2. **Tests are sufficient**: Existing test suite covers the invariants being preserved.

3. **Inliner stays disabled, code kept**: `MonoInlineSimplify.optimize` call remains commented out during this work. The inliner code is modernized but NOT removed.

4. **Bottom-up traversal is correct**: All affected functions want children processed before parent.

5. **Lambda ID uniqueness is the only requirement**: Order of ID generation doesn't affect correctness.

6. **No new module needed**: Shared types can live in `MonoGlobalOptimize.elm`.

7. **MonoLet needs special handling**: Due to `CallEnv` scoping requirements, `MonoLet` keeps manual recursion in `annotateExprCalls`.

8. **ABI normalization stays self-contained**: Case/if ABI logic remains in dedicated functions; no ABI logic in generic traversal callbacks.

---

## Estimated Scope

| Step | Lines Removed | Lines Added | Risk |
|------|---------------|-------------|------|
| Step 1 | ~130 | ~15 | Low |
| Step 2 | ~80 | ~25 | Low |
| Step 3 | ~300 | ~80 | Medium |
| Step 4 | ~50 | ~15 | Low |
| Step 5 | ~100 | ~60 | Medium |
| Step 6 | ~80 | ~30 | Low |
| Step 7 | ~20 | ~30 | Low |
| Step 8 | ~5 | ~5 | Low |
| **Total** | **~765** | **~260** | |

Net reduction: ~505 lines of code.

Note: Step 1 and Step 2 estimates updated to reflect the hybrid approaches (keeping case/if and MonoLet with specialized handling).
