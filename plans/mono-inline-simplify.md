# Mono Inline Simplify Implementation Plan

## Overview

This plan implements the **Mono IR Inliner + Simplifier** pass as specified in `design_docs/mono-ir-simplifier.md`. The goal is to reduce/eliminate higher-order "pipeline plumbing" before it becomes ECO closures/PAPs, running after monomorphization and before MLIR generation.

## Affected Files

| Action | File |
|--------|------|
| **NEW** | `compiler/src/Compiler/Optimize/MonoInlineSimplify.elm` |
| **EDIT** | `compiler/src/Compiler/Generate/MLIR/Backend.elm` |
| **NEW** | `compiler/tests/Compiler/Optimize/MonoInlineSimplifyTest.elm` |

## Design Decisions (All Resolved)

| Decision | Choice |
|----------|--------|
| Fresh variable naming | Global counter: `$inline_0`, `$inline_1`, ... |
| MonoCycle handling | Optimize expressions but mark all cycle members as recursive (no inlining) |
| Mode-based aggressiveness | Same optimization in both Dev and Prod modes |
| TypeEnv for whitelist | Yes - pass TypeEnv, support whitelist infrastructure (empty initially, populated later) |
| PAP reduction verification | Add metrics to MonoInlineSimplify (kept available for debugging, not logged) |
| Per-function inlining budget | Maximum 10 inlines per function |
| MonoTailCall handling | Never inline (preserve tail-call optimization) |

## Implementation Steps

### Step 1: Create MonoInlineSimplify.elm Module Structure

Create `compiler/src/Compiler/Optimize/MonoInlineSimplify.elm` with:

```elm
module Compiler.Optimize.MonoInlineSimplify exposing (optimize, Metrics)

import Compiler.AST.Monomorphized as Mono exposing (MonoGraph, MonoNode, MonoExpr, SpecId, Global)
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.Generate.Mode as Mode
import Data.Graph as Graph
import Dict
import EveryDict exposing (EveryDict)
import Set exposing (Set)
```

#### 1.1 Public API

```elm
type alias Metrics =
    { closureCountBefore : Int
    , closureCountAfter : Int
    , inlineCount : Int
    , betaReductions : Int
    , letEliminations : Int
    }

optimize : Mode.Mode -> TypeEnv.GlobalTypeEnv -> Mono.MonoGraph -> ( Mono.MonoGraph, Metrics )
```

### Step 2: Implement "AlwaysInline" Whitelist Infrastructure

```elm
type alias InlineWhitelist =
    Set ( List String, String )  -- (module path, name)

-- Empty for now, will be populated in the future
defaultWhitelist : InlineWhitelist
defaultWhitelist =
    Set.empty

isWhitelisted : InlineWhitelist -> Global -> Bool
isWhitelisted whitelist (Mono.Global (IO.Canonical _ modulePath) name) =
    Set.member ( modulePath, name ) whitelist
```

The whitelist infrastructure is in place but empty. Future additions can simply add entries to `defaultWhitelist`.

### Step 3: Implement Call Graph Construction

Build a call graph from the MonoGraph nodes:

```elm
type alias CallGraph =
    { edges : Dict SpecId (List SpecId)  -- caller -> callees
    , isRecursive : Dict SpecId Bool     -- SCC-based recursion detection
    }

buildCallGraph : EveryDict Int SpecId MonoNode -> CallGraph
```

**Implementation details:**
- Walk each `MonoNode` body via `collectCalls : MonoExpr -> List SpecId`
- For each `MonoVarGlobal _ specId _`, record the edge
- Use `Data.Graph.stronglyConnComp` (from guida-lang/graph) to compute SCCs
- Mark any specId appearing in a CyclicSCC as recursive

**MonoCycle handling:**
- For `MonoCycle` nodes, mark all specIds involved in the cycle as recursive
- Still optimize the expressions within (let simplification, case simplification, etc.)
- But never inline calls to cycle members

### Step 4: Implement Cost Model

```elm
type alias Cost = Int

computeCost : MonoExpr -> Cost
```

**Cost weights:**
| Expression | Cost |
|------------|------|
| Literal, VarLocal, VarGlobal, VarKernel, Unit | 1 |
| Let, Destruct, If | 2 |
| RecordCreate, TupleCreate, List, Case | 3 |
| Call, Closure | 5 |

**Inlining threshold:** cost <= 20

**AlwaysInline override:** Functions in whitelist are inlined regardless of cost (but still respecting recursion guard and per-function budget).

### Step 5: Implement Expression Rewriting Engine

#### 5.1 Core Rewriter Structure

```elm
type alias RewriteCtx =
    { nodes : EveryDict Int SpecId MonoNode
    , registry : Mono.SpecializationRegistry
    , callGraph : CallGraph
    , whitelist : InlineWhitelist
    , inlineCountThisFunction : Int  -- max 10 per function
    , varCounter : Int  -- for fresh variable generation ($inline_0, $inline_1, ...)
    , metrics : Metrics
    }

maxInlinesPerFunction : Int
maxInlinesPerFunction =
    10

rewrite : RewriteCtx -> MonoExpr -> ( MonoExpr, RewriteCtx )
```

#### 5.2 Fresh Variable Generation

```elm
freshVar : RewriteCtx -> ( String, RewriteCtx )
freshVar ctx =
    ( "$inline_" ++ String.fromInt ctx.varCounter
    , { ctx | varCounter = ctx.varCounter + 1 }
    )
```

#### 5.3 Beta Reduction

Transform `MonoCall (MonoClosure info body _) args _` into:
```elm
-- ((\x y -> body) arg1 arg2) becomes:
-- let $inline_0 = arg1 in let $inline_1 = arg2 in body[x := $inline_0, y := $inline_1]
```

**Key concerns:**
- Preserve strictness: arguments bound to fresh vars before substitution
- Handle partial application (fewer args than params): return closure with remaining params
- Handle over-application (more args than params): apply remaining args to result

**Metrics:** Increment `betaReductions` on each successful beta reduction.

#### 5.4 Direct Call Inlining

For `MonoCall (MonoVarGlobal _ specId _) args resultType`:
1. Check: `inlineCountThisFunction < maxInlinesPerFunction` (budget check)
2. Look up callee in `nodes`
3. Look up Global name via `registry.reverseMapping`
4. Check: not recursive (whitelisted functions still cannot be self-recursive)
5. Check: cost below threshold OR whitelisted
6. Alpha-rename callee locals using `freshVar`
7. Bind parameters to fresh vars via `MonoLet`
8. Splice callee body
9. Increment `inlineCountThisFunction`

```elm
inlineCall : RewriteCtx -> SpecId -> List MonoExpr -> MonoType -> ( Maybe MonoExpr, RewriteCtx )
```

**Metrics:** Increment `inlineCount` on each successful inline.

**MonoTailCall:** Never inline. `MonoTailCall` is preserved as-is to maintain tail-call optimization.

#### 5.5 Let Simplification

```elm
simplifyLet : RewriteCtx -> MonoExpr -> ( MonoExpr, RewriteCtx )
```

Rules:
- `let x = v in body` where x not used in body → drop, return body
- `let x = y in body` where y is VarLocal/Literal → substitute x with y in body
- `let x = expr in body` where x used exactly once and expr is "trivial" → substitute

**Trivial expressions:** VarLocal, VarGlobal (non-function), Literal, Unit

**Metrics:** Increment `letEliminations` for each eliminated let.

#### 5.6 Dead Code Elimination

```elm
dce : MonoExpr -> MonoExpr
```

- Remove unused let bindings (already handled in simplifyLet)
- Collapse identity lambdas: `\x -> x` applied to arg → arg
- Remove unreachable case branches (if scrutinee is known)

#### 5.7 Case Simplification

```elm
simplifyCase : MonoExpr -> MonoExpr
```

Rules:
- If scrutinee is `MonoLiteral` or known constructor, select appropriate branch
- If all branches return identical expressions, collapse to that expression
- For `MonoIf`, if condition is `MonoLiteral (LBool True/False)`, select branch

### Step 6: Implement Fixpoint Loop

```elm
optimizeNode : RewriteCtx -> MonoNode -> ( MonoNode, RewriteCtx )
optimizeNode ctx node =
    -- Reset per-function inline count at start of each node
    let
        ctxForNode = { ctx | inlineCountThisFunction = 0 }
    in
    case node of
        Mono.MonoDefine expr tipe ->
            let ( optimized, newCtx ) = fixpoint ctxForNode expr
            in ( Mono.MonoDefine optimized tipe, newCtx )

        Mono.MonoTailFunc params expr tipe ->
            let ( optimized, newCtx ) = fixpoint ctxForNode expr
            in ( Mono.MonoTailFunc params optimized tipe, newCtx )

        Mono.MonoCycle defs tipe ->
            -- Optimize each definition but don't inline cycle members
            let ( optimizedDefs, newCtx ) = optimizeCycleDefs ctxForNode defs
            in ( Mono.MonoCycle optimizedDefs tipe, newCtx )

        Mono.MonoPortIncoming expr tipe ->
            let ( optimized, newCtx ) = fixpoint ctxForNode expr
            in ( Mono.MonoPortIncoming optimized tipe, newCtx )

        Mono.MonoPortOutgoing expr tipe ->
            let ( optimized, newCtx ) = fixpoint ctxForNode expr
            in ( Mono.MonoPortOutgoing optimized tipe, newCtx )

        -- MonoCtor, MonoEnum, MonoExtern pass through unchanged
        _ ->
            ( node, ctx )

fixpoint : RewriteCtx -> MonoExpr -> ( MonoExpr, RewriteCtx )
fixpoint ctx expr =
    let
        maxIterations = 4

        iterate : Int -> MonoExpr -> RewriteCtx -> ( MonoExpr, RewriteCtx )
        iterate n current currentCtx =
            if n >= maxIterations then
                ( current, currentCtx )
            else
                let
                    ( rewritten, ctx1 ) = rewrite currentCtx current
                    ( simplified, ctx2 ) = simplifyLet ctx1 rewritten
                    final = dce simplified
                in
                if final == current then
                    ( final, ctx2 )
                else
                    iterate (n + 1) final ctx2
    in
    iterate 0 expr ctx
```

### Step 7: Implement Metrics Collection

```elm
emptyMetrics : Metrics
emptyMetrics =
    { closureCountBefore = 0
    , closureCountAfter = 0
    , inlineCount = 0
    , betaReductions = 0
    , letEliminations = 0
    }

countClosures : MonoExpr -> Int
countClosures expr =
    case expr of
        Mono.MonoClosure _ body _ ->
            1 + countClosures body
        Mono.MonoCall _ func args _ ->
            countClosures func + List.sum (List.map countClosures args)
        Mono.MonoLet (Mono.MonoDef _ bound) body _ ->
            countClosures bound + countClosures body
        Mono.MonoLet (Mono.MonoTailDef _ _ bound) body _ ->
            countClosures bound + countClosures body
        Mono.MonoIf branches final _ ->
            List.sum (List.map (\(c, t) -> countClosures c + countClosures t) branches)
                + countClosures final
        Mono.MonoDestruct _ inner _ ->
            countClosures inner
        Mono.MonoCase _ _ _ branches _ ->
            List.sum (List.map (\(_, e) -> countClosures e) branches)
        Mono.MonoList _ items _ ->
            List.sum (List.map countClosures items)
        Mono.MonoRecordCreate fields _ ->
            List.sum (List.map countClosures fields)
        Mono.MonoRecordAccess inner _ _ _ _ ->
            countClosures inner
        Mono.MonoRecordUpdate inner updates _ ->
            countClosures inner + List.sum (List.map (\(_, e) -> countClosures e) updates)
        Mono.MonoTupleCreate _ items _ ->
            List.sum (List.map countClosures items)
        Mono.MonoTailCall _ args _ ->
            List.sum (List.map (\(_, e) -> countClosures e) args)
        _ ->
            0

countClosuresInNode : MonoNode -> Int
countClosuresInNode node =
    case node of
        Mono.MonoDefine expr _ -> countClosures expr
        Mono.MonoTailFunc _ expr _ -> countClosures expr
        Mono.MonoCycle defs _ -> List.sum (List.map (\(_, e) -> countClosures e) defs)
        Mono.MonoPortIncoming expr _ -> countClosures expr
        Mono.MonoPortOutgoing expr _ -> countClosures expr
        _ -> 0

countClosuresInGraph : EveryDict Int SpecId MonoNode -> Int
countClosuresInGraph nodes =
    EveryDict.foldl compare
        (\_ node acc -> acc + countClosuresInNode node)
        0
        nodes
```

### Step 8: Wire Into MLIR Backend

Edit `compiler/src/Compiler/Generate/MLIR/Backend.elm`:

#### 8.1 Add Import

```elm
import Compiler.Optimize.MonoInlineSimplify as MonoInlineSimplify
```

#### 8.2 Modify generateMlirModule

**Before:**
```elm
generateMlirModule mode _ (Mono.MonoGraph { nodes, main, registry, ctorShapes }) =
    let
        signatures = ...
```

**After:**
```elm
generateMlirModule mode typeEnv monoGraph0 =
    let
        ( Mono.MonoGraph { nodes, main, registry, ctorShapes }, _metrics ) =
            MonoInlineSimplify.optimize mode typeEnv monoGraph0

        signatures = ...
```

Note: `_metrics` is available for debugging but not logged by default.

### Step 9: Add Tests

Create `compiler/tests/Compiler/Optimize/MonoInlineSimplifyTest.elm`:

#### 9.1 Unit Tests for Rewrite Rules

```elm
suite : Test
suite =
    describe "MonoInlineSimplify"
        [ describe "Beta reduction"
            [ test "reduces immediate lambda application" <| ...
            , test "handles partial application" <| ...
            , test "handles over-application" <| ...
            ]
        , describe "Let elimination"
            [ test "removes unused binding" <| ...
            , test "substitutes trivial binding" <| ...
            , test "substitutes single-use binding" <| ...
            ]
        , describe "Case simplification"
            [ test "selects branch for known literal" <| ...
            , test "collapses identical branches" <| ...
            ]
        , describe "Inlining"
            [ test "inlines small non-recursive function" <| ...
            , test "skips recursive function" <| ...
            , test "respects max 10 inlines per function" <| ...
            , test "never inlines MonoTailCall" <| ...
            ]
        , describe "Metrics"
            [ test "reports closure count before and after" <| ...
            ]
        ]
```

#### 9.2 Integration Test

```elm
pipelineOptimizationTest : Test
pipelineOptimizationTest =
    test "pipeline reduces closure count" <|
        \_ ->
            let
                ( _, metrics ) = MonoInlineSimplify.optimize mode typeEnv pipelineGraph
            in
            Expect.atMost metrics.closureCountAfter metrics.closureCountBefore
```

## Implementation Order

1. **Phase 1: Scaffolding** (get it compiling)
   - Create MonoInlineSimplify.elm with `optimize` returning `(input, emptyMetrics)`
   - Wire into Backend.elm
   - Verify compilation still works (`cmake --build build --target check`)

2. **Phase 2: Infrastructure**
   - Implement `countClosures` / `countClosuresInGraph` for metrics
   - Implement call graph construction with `collectCalls`
   - Implement SCC-based recursion detection
   - Implement cost model
   - Implement whitelist infrastructure (empty)

3. **Phase 3: Rewrite Rules** (incremental, test each)
   - Let simplification (easiest, most impact)
   - Case simplification
   - Beta reduction
   - Direct call inlining (with 10-inline budget)

4. **Phase 4: Fixpoint & Polish**
   - Implement fixpoint iteration
   - Add DCE
   - Tune thresholds based on test results

5. **Phase 5: Testing**
   - Add unit tests for each rewrite rule
   - Add integration tests
   - Verify PAP reduction with real examples

## Assumptions

1. **No side effects in MonoExpr**: All MonoExpr constructs are pure, so reordering/eliminating is safe.

2. **Strictness preserved by let bindings**: The beta-reduction transforms `((\x -> body) arg)` into `let x = arg in body`, which evaluates `arg` exactly once before body, preserving strict semantics.

3. **The guida-lang/graph package provides SCC**: Based on codebase analysis, `Data.Graph.stronglyConnComp` is available.

4. **Limited explosion risk**: The fixpoint is capped at 4 iterations and inlining is limited to 10 per function, preventing unbounded code growth.

5. **No cross-module debugging concerns**: The optimizer operates on the fully monomorphized graph where module boundaries are already erased.

6. **MonoTailCall preservation is correct**: By never inlining `MonoTailCall`, we ensure tail-call optimization is preserved in the generated code.
