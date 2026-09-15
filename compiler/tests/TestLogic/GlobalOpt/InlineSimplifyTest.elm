module TestLogic.GlobalOpt.InlineSimplifyTest exposing (suite)

{-| Test suite for the PRE-monomorphization inliner
(`plans/pre-mono-inline-simplify.md` §6).

The pass runs on the `TOpt.GlobalGraph`, i.e. BEFORE `MonoSolver`, so these
tests take `Pipeline.runToMono`'s `globalGraph` — which is exactly the graph
`Builder.Generate.runMonoOptPipeline` hands to `InlineSimplify.optimize` — and
call `optimize` on it directly.

What is pinned:

  - the candidate index is non-empty and excludes recursive globals (Step 3);
  - an exact-arity call to a small global is actually inlined (Step 4);
  - the pass is a no-op when `preMono` admits nothing (budget 0);
  - metrics never go negative and the graph keeps every node.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , callExpr
        , define
        , intExpr
        , letExpr
        , makeModuleWithTypedDefsUnionsAliases
        , negateExpr
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)
import Compiler.Eco.Config as Config
import Compiler.GlobalOpt.InlineSimplify as InlineSimplify
import Data.Map
import Dict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "InlineSimplify (pre-mono)"
        [ candidateSuite
        , inlineSuite
        , budgetSuite
        ]



-- ============================================================================
-- CANDIDATES (Step 3)
-- ============================================================================


candidateSuite : Test
candidateSuite =
    Test.describe "Candidate index"
        [ Test.test "the pass examines top-level bodies at all" <|
            \_ ->
                -- The denominator whose zero is impossible. `candidates = 0`
                -- reads identically whether the pass refused everything or
                -- never matched a node shape at all; `bodiesSeen` separates
                -- them, and the first version of `buildCandidates` matched
                -- only `Define`/`Function` and saw almost nothing.
                withMetrics addOneModule
                    (\m ->
                        if m.bodiesSeen > 0 then
                            Expect.pass

                        else
                            Expect.fail "buildCandidates matched no top-level body"
                    )
        , Test.test "a small non-recursive global is a candidate" <|
            \_ ->
                withMetrics addOneModule
                    (\m ->
                        if m.candidates > 0 then
                            Expect.pass

                        else
                            Expect.fail "expected at least one inline candidate"
                    )
        , Test.test "a recursive global never becomes a candidate" <|
            \_ ->
                -- Asserted as "no body was even offered", which is what the
                -- front end actually produces: a self-recursive definition is
                -- emitted as a `Cycle` node, and `bodyOf` refuses those. The
                -- `recursiveSkipped` counter exists for the other route — a
                -- `Define` that reaches itself through the dependency SCC, or
                -- names itself in its body — and does not fire on this shape.
                withMetrics countDownModule
                    (\m -> Expect.equal ( 0, 0 ) ( m.bodiesSeen, m.candidates ))
        , Test.test "a recursive global is not inlined" <|
            \_ ->
                withMetrics countDownModule (\m -> Expect.equal 0 m.inlineCount)
        ]



-- ============================================================================
-- INLINING (Step 4)
-- ============================================================================


inlineSuite : Test
inlineSuite =
    Test.describe "Inlining"
        [ Test.test "an exact-arity call to a small global is inlined" <|
            \_ ->
                withMetrics addOneModule
                    (\m ->
                        if m.inlineCount > 0 then
                            Expect.pass

                        else
                            Expect.fail "expected at least one inline"
                    )
        , Test.test "the inlined callee is attributed by name" <|
            \_ ->
                withMetrics addOneModule
                    (\m ->
                        if Dict.isEmpty m.inlinedByCallee then
                            Expect.fail "inlinedByCallee is empty despite inlineCount > 0"

                        else
                            Expect.pass
                    )
        , Test.test "the node set is preserved" <|
            \_ ->
                withGraphs addOneModule
                    (\before after ->
                        Expect.equal (nodeCount before) (nodeCount after)
                    )
        ]



-- ============================================================================
-- BUDGET
-- ============================================================================


budgetSuite : Test
budgetSuite =
    Test.describe "Budget"
        [ Test.test "threshold 0 admits nothing and inlines nothing" <|
            \_ ->
                case Pipeline.runToAssigned addOneModule of
                    Err msg ->
                        Expect.fail msg

                    Ok assigned ->
                        let
                            ( _, _, m ) =
                                InlineSimplify.optimize
                                    { inlineConfig | preMonoThreshold = 0 }
                                    assigned.mvarState
                                    assigned.graph
                        in
                        Expect.equal ( 0, 0 ) ( m.candidates, m.inlineCount )
        ]



-- ============================================================================
-- HELPERS
-- ============================================================================


inlineConfig : Config.InlineConfig
inlineConfig =
    { defaultInline | preMono = True }


defaultInline : Config.InlineConfig
defaultInline =
    Config.default.inline


withMetrics : Src.Module -> (InlineSimplify.Metrics -> Expect.Expectation) -> Expect.Expectation
withMetrics srcModule check =
    case Pipeline.runToAssigned srcModule of
        Err msg ->
            Expect.fail msg

        Ok assigned ->
            let
                ( _, _, m ) =
                    InlineSimplify.optimize inlineConfig assigned.mvarState assigned.graph
            in
            check m


withGraphs :
    Src.Module
    -> (TOpt.GlobalGraph TypeIds.MVarId -> TOpt.GlobalGraph TypeIds.MVarId -> Expect.Expectation)
    -> Expect.Expectation
withGraphs srcModule check =
    case Pipeline.runToAssigned srcModule of
        Err msg ->
            Expect.fail msg

        Ok assigned ->
            let
                ( after, _, _ ) =
                    InlineSimplify.optimize inlineConfig assigned.mvarState assigned.graph
            in
            check assigned.graph after


nodeCount : TOpt.GlobalGraph TypeIds.MVarId -> Int
nodeCount (TOpt.GlobalGraph nodes _ _ _ _) =
    Data.Map.size nodes



-- ============================================================================
-- FIXTURES
-- ============================================================================


{-| addOne : Int -> Int
addOne x = x

    testValue : Int
    testValue =
        addOne 41

**No arithmetic on purpose.** The shared test harness leaves bare `TVar`s on
`Binop` nodes — that is what this suite's pre-existing `POST_010` / `TYPE_007`
failures report — and `isGround` refuses a body carrying one. A binop fixture
therefore measures the harness's type coverage, not the inliner.

-}
addOneModule : Src.Module
addOneModule =
    let
        addOneDef : TypedDef
        addOneDef =
            { name = "addOne"
            , args = [ pVar "x" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = varExpr "x"
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "addOne") [ intExpr 41 ]
            }
    in
    makeModuleWithTypedDefsUnionsAliases "Test" [ addOneDef, testValueDef ] [] []


{-| countDown : Int -> Int
countDown n = negate (countDown n)

    testValue : Int
    testValue =
        countDown 3

A self-recursive global whose recursive call is NOT in tail position, so it is
a real `VarGlobal` reference to itself and inlining it would not terminate.

The `negate` wrapper is load-bearing. Written as the tail call
`countDown n = countDown n`, the front end compiles the recursion into a local
`Case`/`TailCall` loop with no `VarGlobal` self-reference at all — and such a
function IS safely inlinable, because the loop is copied along with the body
and stays self-contained. The guard exists for the non-tail case.

-}
countDownModule : Src.Module
countDownModule =
    let
        countDownDef : TypedDef
        countDownDef =
            { name = "countDown"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = negateExpr (callExpr (varExpr "countDown") [ varExpr "n" ])
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "countDown") [ intExpr 3 ]
            }
    in
    makeModuleWithTypedDefsUnionsAliases "Test" [ countDownDef, testValueDef ] [] []
