module TestLogic.GlobalOpt.InlineSimplifyTest exposing (suite)

{-| Tests for `Compiler.GlobalOpt.InlineSimplify`, the inliner that runs on the
typed global graph before monomorphization.

The pass is off by default in a build, and none of the `TestPipeline` stages
runs it, so without these tests a change that stopped it finding anything to
inline, made it inline the self-recursive fixture, or made it ignore its size
threshold would go unnoticed. What a candidate is, and which globals are refused, is
described in `Compiler.GlobalOpt.InlineSimplify`. In brief, a _candidate_ is a
top-level function the pass is willing to inline, and the pass reports what it
did as a `Metrics` record of counters.

Every test builds a one-module program, runs `TestPipeline.runToAssigned` on it
to get the global graph with its type ids assigned, and calls
`InlineSimplify.optimize` on that graph directly. A pipeline failure fails the
test. The graph is not quite the one a build hands to the pass: a build with
alias forwarding and eta-expansion switched on, as they are by default, first
applies them to it, and a build assigns ids with the flags of the engine it
uses.

There are two fixtures. `addOneModule` has a one-parameter `addOne` and a
`testValue` that calls it with one argument. `countDownModule` has a
`countDown` that calls itself and a `testValue` that calls it.

What the tests establish:

  - On `addOneModule`, `bodiesSeen` is above zero, so the pass recognised at
    least one top-level function body.
  - On `addOneModule`, `candidates` is above zero.
  - On `countDownModule`, `bodiesSeen` and `candidates` are both zero: the
    recursive global is never offered to the pass as a body at all.
  - On `countDownModule`, `inlineCount` is zero.
  - On `addOneModule`, `inlineCount` is above zero.
  - On `addOneModule`, `inlinedByCallee` is not empty. Which name it holds is
    not checked.
  - On `addOneModule`, the graph has as many nodes after the pass as before.
  - On `addOneModule` with `preMonoThreshold` set to 0, `candidates` and
    `inlineCount` are both zero.

Among what is not tested: the rewritten expressions themselves (only counters
and the node count are read), a polymorphic candidate or a call site that does
not fix its types, the refusals for function-typed parameters, open records,
polymorphic kernel references and constrained type variables, a call with the
wrong number of arguments, mutual recursion, a recursive global the pass does
see as a body, and the repeated rounds.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , callExpr
        , intExpr
        , makeModuleWithTypedDefsUnionsAliases
        , negateExpr
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Eco.Config as Config
import Compiler.GlobalOpt.InlineSimplify as InlineSimplify
import Data.Map
import Dict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The inliner tests, in three groups: which globals become candidates, what
is inlined, and the effect of a zero threshold.
-}
suite : Test
suite =
    Test.describe "InlineSimplify (pre-mono)"
        [ candidateSuite
        , inlineSuite
        , budgetSuite
        ]



-- ============================================================================
-- CANDIDATES
-- ============================================================================


{-| The tests of which globals the pass examines and admits as candidates, and
that the recursive fixture is not inlined.
-}
candidateSuite : Test
candidateSuite =
    Test.describe "Candidate index"
        [ Test.test "the pass examines top-level bodies at all" <|
            \_ ->
                -- `candidates = 0` reads the same whether the pass refused
                -- every body or recognised none; this rules out the second.
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
                -- The front end puts a self-recursive definition in a `Cycle`
                -- node, which the pass never takes a body from, so its
                -- recursion check and `recursiveSkipped` are not reached here.
                withMetrics countDownModule
                    (\m -> Expect.equal ( 0, 0 ) ( m.bodiesSeen, m.candidates ))
        , Test.test "a recursive global is not inlined" <|
            \_ ->
                withMetrics countDownModule (\m -> Expect.equal 0 m.inlineCount)
        ]



-- ============================================================================
-- INLINING
-- ============================================================================


{-| The tests of what the pass does to `addOneModule`'s call to `addOne`.
-}
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


{-| The test that a `preMonoThreshold` of 0 admits no candidate and inlines
nothing. Every expression costs at least 1 in the pass's measure of size, so no
body fits under that threshold.
-}
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


{-| The inline configuration the tests run the pass with: the default one with
`preMono` switched on.

`optimize` does not read `preMono` itself, so the setting changes nothing here;
`preMonoThreshold` and the number of rounds keep their defaults.

-}
inlineConfig : Config.InlineConfig
inlineConfig =
    { defaultInline | preMono = True }


{-| The default inline configuration from `Compiler.Eco.Config`.
-}
defaultInline : Config.InlineConfig
defaultInline =
    Config.default.inline


{-| Runs the pass with `inlineConfig` on the assigned global graph of
`srcModule` and returns `check` applied to the metrics it reports. A pipeline
failure fails the expectation with its message.
-}
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


{-| Runs the pass with `inlineConfig` on the assigned global graph of
`srcModule` and returns `check` applied to the graph before the pass and the
graph after it, in that order. A pipeline failure fails the expectation with
its message.
-}
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


{-| Returns the number of nodes in a global graph.
-}
nodeCount : TOpt.GlobalGraph TypeIds.MVarId -> Int
nodeCount (TOpt.GlobalGraph nodes _ _ _ _) =
    Data.Map.size nodes



-- ============================================================================
-- FIXTURES
-- ============================================================================


{-| A module named `Test` with one small, non-recursive function and one call
to it with exactly one argument:

    addOne : Int -> Int
    addOne x =
        x

    testValue : Int
    testValue =
        addOne 41

Despite its name, `addOne` returns its argument unchanged, and the fixture does
no arithmetic. The pass never inlines a body with a type variable on one of
its nodes that the call's argument and result types leave unfixed, so a
fixture whose arithmetic the test pipeline left with such a variable would
test the pipeline's typing rather than the inliner.

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


{-| A module named `Test` with one self-recursive function and one call to it:

    countDown : Int -> Int
    countDown n =
        negate (countDown n)

    testValue : Int
    testValue =
        countDown 3

The recursive call is wrapped in `negate`, so it is not a tail call.
`countDown` never returns, but the tests only compile the module and never run
it. The front end puts a self-recursive top-level definition in a `Cycle` node
whether or not its recursive call is a tail call.

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
