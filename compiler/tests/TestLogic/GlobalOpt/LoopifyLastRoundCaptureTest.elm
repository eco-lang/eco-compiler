module TestLogic.GlobalOpt.LoopifyLastRoundCaptureTest exposing (suite)

{-| Tests that a capturing lambda loopified in the post-monomorphization
inliner's last fixpoint round leaves no open closure in the graph. Without
the capture renaming described below, a closure whose body names a variable
that is neither its parameter nor its capture would reach MLIR codegen, which
fails on the unbound name.

`Compiler.GlobalOpt.MonoInlineSimplify.loopifyCall` binds each local capture
of a qualifying lambda literal to a fresh name in a `let` outside the loop and
substitutes that name into the lambda's body. The rebuilt lambda captures the
fresh names, so it is well scoped even if no later round beta-reduces it. The
fixpoint (`iterate`) stops after `postMonoFixpointIterations` rounds (4 in
`Config.default`) whether or not that reduction has happened, so a loopify in
the last round is the case that depends on the captures.

The fixtures are two modules built from source. `myAny` is a user
tail-recursive higher-order function, so the inliner can loopify calls to it.
`hasK` searches a list of lists of `Int`, and `testValue` calls it.

  - `nestedModule`: `hasK k ls = myAny (\xs -> myAny (\x -> x == k) xs) ls`;
    both lambdas capture `k`.
  - `appliedLambdaModule`: the same body inside an immediately applied lambda,
    `hasK k0 ls = (\k -> ...) k0`, which puts one extra reduction in front of
    the first loopify and so shifts the rounds in which the loopifies happen.

The tests establish:

  - with `Config.default.inline`, `MonoInlineSimplify.optimize` on
    `appliedLambdaModule`'s monomorphized graph reports `hofLoopified` = 2 and
    leaves a graph that passes `MonoGraphIntegrity.localVarScopingChecks`;
  - the graph `runToGlobalOpt` produces for `appliedLambdaModule` after the
    inliner, prune and global optimization passes those checks;
  - for each `postMonoFixpointIterations` from 1 to 6, the inliner's output
    for each fixture passes those checks.

Among what is not tested: the loopify count for any round limit other than the
default, the loopify count for `nestedModule`, and codegen of the result.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , ifExpr
        , intExpr
        , lambdaExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pCons
        , pList
        , pVar
        , parensExpr
        , tLambda
        , tType
        , tVar
        , varExpr
        )
import Compiler.AST.Monomorphized as Mono
import Compiler.Eco.Config as Config
import Compiler.GlobalOpt.MonoInlineSimplify as MonoInlineSimplify
import Expect
import Test exposing (Test)
import TestLogic.Generate.MonoGraphIntegrity as Integrity
import TestLogic.TestPipeline as Pipeline


{-| The default-configuration tests and one pair of tests per round limit.
-}
suite : Test
suite =
    Test.describe "MonoInlineSimplify loopify in the last fixpoint round leaves an open closure"
        [ Test.test "default config: applied-lambda fixture is well scoped after the inliner" <|
            \_ ->
                withMono appliedLambdaModule
                    (\graph ->
                        let
                            ( after, metrics ) =
                                MonoInlineSimplify.optimize Config.default.inline graph
                        in
                        Expect.all
                            [ \_ -> Expect.equal 2 metrics.hofLoopified
                            , \_ -> expectWellScoped after
                            ]
                            ()
                    )
        , Test.test "default config: applied-lambda fixture is well scoped after the whole LSS pipeline" <|
            \_ ->
                case Pipeline.runToGlobalOpt appliedLambdaModule of
                    Err msg ->
                        Expect.fail msg

                    Ok artifacts ->
                        expectWellScoped artifacts.optimizedMonoGraph
        , Test.describe "every fixpoint round limit leaves the graph well scoped"
            (List.concatMap
                (\fpi ->
                    [ Test.test ("applied-lambda fixture, postMonoFixpointIterations = " ++ String.fromInt fpi) <|
                        \_ -> withMono appliedLambdaModule (expectWellScopedAt fpi)
                    , Test.test ("nested fixture, postMonoFixpointIterations = " ++ String.fromInt fpi) <|
                        \_ -> withMono nestedModule (expectWellScopedAt fpi)
                    ]
                )
                (List.range 1 6)
            )
        ]


{-| Applies `check` to the monomorphized graph of `srcModule`: the
`monoGraph` of `runToGlobalOpt`, taken before the pipeline's own inliner runs.
Fails with the pipeline's message if the pipeline fails.
-}
withMono : Src.Module -> (Mono.MonoGraph -> Expect.Expectation) -> Expect.Expectation
withMono srcModule check =
    case Pipeline.runToGlobalOpt srcModule of
        Err msg ->
            Expect.fail msg

        Ok artifacts ->
            check artifacts.monoGraph


{-| Runs the inliner with `Config.default.inline` and the given
`postMonoFixpointIterations` on `graph`, and expects the result to pass the
local-variable scoping checks.
-}
expectWellScopedAt : Int -> Mono.MonoGraph -> Expect.Expectation
expectWellScopedAt fpi graph =
    let
        base =
            Config.default.inline

        ( after, _ ) =
            MonoInlineSimplify.optimize { base | postMonoFixpointIterations = fpi } graph
    in
    expectWellScoped after


{-| Passes when `graph` has no out-of-scope local reference
(`MonoGraphIntegrity.localVarScopingChecks`); otherwise fails with every
failing check.
-}
expectWellScoped : Mono.MonoGraph -> Expect.Expectation
expectWellScoped graph =
    case Integrity.localVarScopingChecks graph of
        [] ->
            Expect.pass

        checks ->
            Expect.all checks ()



-- FIXTURES


{-| The source type `Int`.
-}
tInt : Src.Type
tInt =
    tType "Int" []


{-| The source type `Bool`.
-}
tBool : Src.Type
tBool =
    tType "Bool" []


{-| The source type `List t`.
-}
tList : Src.Type -> Src.Type
tList t =
    tType "List" [ t ]


{-| `myAny f l = case l of [] -> False; x :: rest -> if f x then True else myAny f rest`,
a tail-recursive HOF whose `f` is called once and threaded verbatim, so it is
loopifiable (`buildLoopifiables`).
-}
myAnyDef : TypedDef
myAnyDef =
    { name = "myAny"
    , args = [ pVar "f", pVar "l" ]
    , tipe = tLambda (tLambda (tVar "a") tBool) (tLambda (tList (tVar "a")) tBool)
    , body =
        caseExpr (varExpr "l")
            [ ( pList [], boolExpr False )
            , ( pCons (pVar "x") (pVar "rest")
              , ifExpr (callExpr (varExpr "f") [ varExpr "x" ])
                    (boolExpr True)
                    (callExpr (varExpr "myAny") [ varExpr "f", varExpr "rest" ])
              )
            ]
    }


{-| `myAny (\xs -> myAny (\x -> x == k) xs) ls`: both lambdas capture `k`.
-}
nestedAny : Src.Expr
nestedAny =
    callExpr (varExpr "myAny")
        [ lambdaExpr [ pVar "xs" ]
            (callExpr (varExpr "myAny")
                [ lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "==" ) ] (varExpr "k"))
                , varExpr "xs"
                ]
            )
        , varExpr "ls"
        ]


{-| A module `Test` with `myAny`, a `hasK : Int -> List (List Int) -> Bool`
with the given arguments and body, and `testValue = hasK 3 [ [ 1 ], [ 3 ] ]`.
-}
fixture : List Src.Pattern -> Src.Expr -> Src.Module
fixture hasKArgs hasKBody =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ myAnyDef
        , { name = "hasK"
          , args = hasKArgs
          , tipe = tLambda tInt (tLambda (tList (tList tInt)) tBool)
          , body = hasKBody
          }
        , { name = "testValue"
          , args = []
          , tipe = tBool
          , body = callExpr (varExpr "hasK") [ intExpr 3, listExpr [ listExpr [ intExpr 1 ], listExpr [ intExpr 3 ] ] ]
          }
        ]
        []
        []


{-| The fixture with `hasK k0 ls = (\k -> myAny (\xs -> myAny (\x -> x == k) xs) ls) k0`.
-}
appliedLambdaModule : Src.Module
appliedLambdaModule =
    fixture [ pVar "k0", pVar "ls" ]
        (callExpr (parensExpr (lambdaExpr [ pVar "k" ] nestedAny)) [ varExpr "k0" ])


{-| The fixture with `hasK k ls = myAny (\xs -> myAny (\x -> x == k) xs) ls`.
-}
nestedModule : Src.Module
nestedModule =
    fixture [ pVar "k", pVar "ls" ] nestedAny
