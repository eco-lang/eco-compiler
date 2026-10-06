module TestLogic.GlobalOpt.LoopifyLastRoundCaptureTest exposing (suite)

{-| Regression tests for a scoping bug in the post-monomorphization inliner,
`Compiler.GlobalOpt.MonoInlineSimplify`: when H5 loopification of a
CAPTURING lambda literal happens in the LAST fixpoint round the inliner is
allowed (`inline.postMonoFixpointIterations`, default 4), the output graph
held a closure whose body names a variable that is neither its parameter
nor its capture. MLIR codegen then crashed with

    lookupVar: unbound variable mono_inline_N [in <Module>_lambda_M; in-scope mono_inline: ]

which is how the bug was found: a self-compile with
`{"inline": {"postMonoFixpointIterations": 5}}` crashed in
`MonoCse.dropOverlapping` (a `List.foldl` over a `List.any` over a
`List.any` with a capturing lambda: three nested loopifies, the third in
round index 4).

**Root cause.** `loopifyCall` (MonoInlineSimplify.elm, the `lambdaPairs`
fold, around line 2190-2225) re-binds every capture of the qualifying
lambda to a fresh `mono_inline_N` name in a prelude `let` OUTSIDE the loop,
substitutes that name into the lambda's body, and then rebuilt the lambda
with `captures = []`. The rebuilt closure was deliberately OPEN: it was only
well scoped once the beta arm of `rewriteExpr` reduces
`(\b -> ...) @ x` at its single call site inside the loop, which happens in
the NEXT fixpoint round (the comment in `rewriteExpr`'s direct-call arm,
"the fixpoint's next iteration beta-reduces the inlined lambda literal").
`iterate` (around line 2798) stops at `n >= maxIterations` without checking
that this pending beta has happened, so a loopify in round index
`maxIterations - 1` left the open closure in the graph.

**Fix.** The rebuilt lambda now captures the fresh prelude names, so it is
closed whether or not a later round beta-reduces it (`betaReduce` ignores
captures).

Each nested loopify level costs two rounds (loopify, then beta, which
exposes the next level's call), so nested loopifies alone land in EVEN round
indices and only odd round limits (1, 3, 5, ...) hit the bug. One extra
round in front of the first loopify — here an immediately applied lambda
`(\k -> ...) k0`, which is beta-reduced in round 0 without rewriting its
body — moves every loopify to an ODD round index, so the DEFAULT limit of 4
cuts between the second loopify (round 3) and its beta (round 4). The same
program as an E2E source (`hasK k0 ls = k0 |> (\k -> myAny (\xs -> myAny
(\x -> x == k) xs) ls)`) crashed `eco make` with the default config.

The fixtures (`myAny` is a user tail-recursive HOF, so it is loopifiable;
the test pipeline has no node bodies for `List.any`):

  - `appliedLambdaModule`: `hasK k0 ls = (\k -> myAny (\xs -> myAny (\x -> x == k) xs) ls) k0`.
    Two loopifies, in rounds 1 and 3.
  - `nestedModule`: `hasK k ls = myAny (\xs -> myAny (\x -> x == k) xs) ls`.
    Two loopifies, in rounds 0 and 2.

The tests establish, by `MonoGraphIntegrity.localVarScopingChecks` (the
MONO\_011 local-variable half of `expectMonoGraphClosed`):

  - with the default inline configuration, `appliedLambdaModule`'s graph is
    well scoped after `MonoInlineSimplify.optimize` and after the whole
    `runToGlobalOpt` pipeline (before the fix: `MONO_011: MonoVarLocal 'mono_inline_11' is not
    in scope at SpecId 3`), and both loopifies happened (so the
    check is not vacuous);
  - for every round limit 1..6, both fixtures are well scoped after the
    inliner (before the fix these failed at 2 and 4 for `appliedLambdaModule`,
    and at 1 and 3 for `nestedModule`).

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


{-| Monomorphizes `srcModule` as a default build does (solver engine, LSS
on; the `monoGraph` of `runToGlobalOpt`, taken before its own inliner
runs) and applies `check` to the graph.
-}
withMono : Src.Module -> (Mono.MonoGraph -> Expect.Expectation) -> Expect.Expectation
withMono srcModule check =
    case Pipeline.runToGlobalOpt srcModule of
        Err msg ->
            Expect.fail msg

        Ok artifacts ->
            check artifacts.monoGraph


expectWellScopedAt : Int -> Mono.MonoGraph -> Expect.Expectation
expectWellScopedAt fpi graph =
    let
        base =
            Config.default.inline

        ( after, _ ) =
            MonoInlineSimplify.optimize { base | postMonoFixpointIterations = fpi } graph
    in
    expectWellScoped after


expectWellScoped : Mono.MonoGraph -> Expect.Expectation
expectWellScoped graph =
    case Integrity.localVarScopingChecks graph of
        [] ->
            Expect.pass

        checks ->
            Expect.all checks ()



-- FIXTURES


tInt : Src.Type
tInt =
    tType "Int" []


tBool : Src.Type
tBool =
    tType "Bool" []


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


{-| `hasK k0 ls = (\k -> myAny (\xs -> myAny (\x -> x == k) xs) ls) k0` -}
appliedLambdaModule : Src.Module
appliedLambdaModule =
    fixture [ pVar "k0", pVar "ls" ]
        (callExpr (parensExpr (lambdaExpr [ pVar "k" ] nestedAny)) [ varExpr "k0" ])


{-| `hasK k ls = myAny (\xs -> myAny (\x -> x == k) xs) ls` -}
nestedModule : Src.Module
nestedModule =
    fixture [ pVar "k", pVar "ls" ] nestedAny
