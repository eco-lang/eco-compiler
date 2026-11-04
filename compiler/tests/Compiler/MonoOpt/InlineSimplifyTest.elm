module Compiler.MonoOpt.InlineSimplifyTest exposing (suite)

{-| Pins the metrics of the post-monomorphization inliner,
`Compiler.MonoOpt.InlineSimplify.optimize`, on four small fixtures, each built
for one rewrite: that the counter of that rewrite is positive.

Each fixture is a module named `Test` with one annotated `testValue : Int`,
turned into a monomorphized graph by `TestLogic.TestPipeline.runToMono`; the
inliner is then called with `Config.default.inline`. The tests establish:

  - an `identity : Int -> Int` applied to 42: `inlineCount` is at least 1;
  - a `let` that binds 42 and returns 7: `letEliminations` is at least 1;
  - the lambda `\x -> x` applied to 42: `betaReductions` is at least 1;
  - two nested `let`s that bind 1 and 2 and return 3: `letEliminations` is at
    least 2.

A `runToMono` error fails the test with its message. Over the standard
catalogue, `TestLogic.GlobalOpt.MonoInlineSimplifyTest` checks the inliner's
output for dangling SpecIds and orphaned tail calls; the catalogue holds
programs of the same shapes (`SourceIR.SpecializeExprCases`' polymorphic
`identity 42`, `SourceIR.LetCases`' unused and nested unused `let`s,
`SourceIR.FunctionCases`' directly applied lambda).

Among what is not tested: that the optimized graph computes the same values,
and the exact values of the counters.

-}

import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , callExpr
        , define
        , intExpr
        , lambdaExpr
        , letExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import Compiler.Config as Config
import Compiler.IR.Source as Src
import Compiler.MonoOpt.InlineSimplify as MonoInlineSimplify
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The tests that the inliner does, on each of the four fixtures, the rewrite
the fixture is built for, as its metrics count it.
-}
suite : Test
suite =
    Test.describe "Optimizer rewrites each fixture"
        [ Test.test "a call of an identity function is inlined" <|
            \_ ->
                expectMetric "inlineCount" .inlineCount 1 simpleIdentityModule
        , Test.test "a let binding is eliminated" <|
            \_ ->
                expectMetric "letEliminations" .letEliminations 1 simpleLetModule
        , Test.test "a lambda applied directly is beta-reduced" <|
            \_ ->
                expectMetric "betaReductions" .betaReductions 1 lambdaApplicationModule
        , Test.test "both nested let bindings are eliminated" <|
            \_ ->
                expectMetric "letEliminations" .letEliminations 2 nestedLetModule
        ]


{-| Runs the inliner on the graph `runToMono` makes from `srcModule`, and
passes when the metric `read` returns, named `label`, is at least `atLeast`.
Fails with the pipeline's message when `runToMono` returns an error.
-}
expectMetric : String -> (MonoInlineSimplify.Metrics -> Int) -> Int -> Src.Module -> Expect.Expectation
expectMetric label read atLeast srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail ("Failed to create MonoGraph: " ++ msg)

        Ok { monoGraph } ->
            let
                ( _, metrics ) =
                    MonoInlineSimplify.optimize Config.default.inline monoGraph
            in
            if read metrics >= atLeast then
                Expect.pass

            else
                Expect.fail
                    ("expected " ++ label ++ " >= " ++ String.fromInt atLeast ++ ", got " ++ String.fromInt (read metrics))


{-| A module whose `testValue` calls an annotated identity function:

    identity : Int -> Int
    identity x =
        x

    testValue : Int
    testValue =
        identity 42

-}
simpleIdentityModule : Src.Module
simpleIdentityModule =
    let
        identityDef : TypedDef
        identityDef =
            { name = "identity"
            , args = [ pVar "x" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = varExpr "x"
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "identity") [ intExpr 42 ]
            }
    in
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ identityDef, testValueDef ]
        []
        []


{-| A module whose `testValue` binds 42 in a `let` it never uses, so the
binding is dead and the inliner drops it:

    testValue : Int
    testValue =
        let
            x =
                42
        in
        7

-}
simpleLetModule : Src.Module
simpleLetModule =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = letExpr [ define "x" [] (intExpr 42) ] (intExpr 7)
            }
    in
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ testValueDef ]
        []
        []


{-| A module whose `testValue` applies a lambda directly to an argument:

    testValue : Int
    testValue =
        (\x -> x) 42

-}
lambdaApplicationModule : Src.Module
lambdaApplicationModule =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr
                    (lambdaExpr [ pVar "x" ] (varExpr "x"))
                    [ intExpr 42 ]
            }
    in
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ testValueDef ]
        []
        []


{-| A module whose `testValue` nests one `let` inside another and uses
neither binding, so both are dead and the inliner drops both:

    testValue : Int
    testValue =
        let
            x =
                1
        in
        let
            y =
                2
        in
        3

-}
nestedLetModule : Src.Module
nestedLetModule =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                letExpr [ define "x" [] (intExpr 1) ]
                    (letExpr [ define "y" [] (intExpr 2) ]
                        (intExpr 3)
                    )
            }
    in
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ testValueDef ]
        []
        []
