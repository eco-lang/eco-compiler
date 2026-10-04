module TestLogic.Generate.CodeGen.E2V2StagedDispatchTest exposing (suite)

{-| Checks that global optimization stamps a closure call that supplies more
arguments than the called lambda's first stage takes. When
`Compiler.GlobalOpt.AbiCloning` declines to stamp a call, it leaves the call
unchanged and reports no error, so without this test a lost stamp would go
unnoticed.

A _stamp_ is what `Compiler.GlobalOpt.AbiCloning` writes into the `CallInfo`
of a call whose callee lambda-set specialization has narrowed to a single
function value: it sets the call's `fastEvaluator` and `captureAbi`. A curried
lambda such as `\a -> \b -> e` takes its arguments in stages, one per lambda,
so its first stage takes one argument. A call that passes it two arguments
_over-applies_ it. A stamp on an over-applied call is a _staged stamp_: its
`captureAbi.paramTypes` are those of the first stage only, so the call has
more arguments than `captureAbi.paramTypes`.

The fixture is one module, run through
`TestLogic.TestPipeline.runToGlobalOptLssOn` (the solver engine with
lambda-set specialization on, then the inliner and global optimization):

    applyStaged : (Int -> Int -> Int) -> Int -> Int -> Int
    applyStaged f n acc =
        if n <= 0 then
            acc

        else
            f 10 (applyStaged f (n - 1) acc)

    testValue : Int
    testValue =
        applyStaged (\a -> \b -> a * 10 + b) 2 3

The call `f 10 (...)` is the over-applied site, and the curried lambda is the
only function value passed for `f`. The recursion is deliberately not a tail
call, so `applyStaged` is not compiled as a tail function; the inliner's
loopification in `Compiler.GlobalOpt.MonoInlineSimplify` considers only tail
functions.

The one test passes when some call in a node of the optimized graph has a
`fastEvaluator`, a `captureAbi`, and more arguments than that `captureAbi`'s
`paramTypes`. It fails when the pipeline returns an error or no call has that
shape.

Among what is not tested: that the stamped call is the `f 10 (...)` site,
which lambda `fastEvaluator` names, the call's other `CallInfo` fields, and how
the MLIR back end emits a staged call.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , callExpr
        , ifExpr
        , intExpr
        , lambdaExpr
        , makeModuleWithTypedDefs
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The module's one test: it runs `fixtureModule` through
`Pipeline.runToGlobalOptLssOn` and passes when `hasStagedStamp` finds a staged
stamp in the optimized graph.
-}
suite : Test
suite =
    Test.describe "E2.7: staged stamp fires on an over-applied singleton"
        [ Test.test "the over-apply site carries a staged stamp (args > captureAbi params)" <|
            \_ ->
                case Pipeline.runToGlobalOptLssOn fixtureModule of
                    Err e ->
                        Expect.fail ("solver+LSS pipeline failed: " ++ e)

                    Ok { optimizedMonoGraph } ->
                        if hasStagedStamp optimizedMonoGraph then
                            Expect.pass

                        else
                            Expect.fail
                                "no call carries a staged stamp (fastEvaluator set, |args| > |captureAbi.paramTypes|) — E2.7 did not fire on `f 10 (…)`"
        ]



-- FIXTURE (DSL) -------------------------------------------------------------


{-| The source type `Int`.
-}
intT : Src.Type
intT =
    tType "Int" []


{-| The source type `Int -> Int`, the result type of `f`'s first stage in
`applyStaged`'s annotation.
-}
int1T : Src.Type
int1T =
    tLambda intT intT


{-| The fixture: a module named `Test` holding the annotated definitions
`applyStaged` and `testValue`.
-}
fixtureModule : Src.Module
fixtureModule =
    makeModuleWithTypedDefs "Test" [ applyStagedDef, testValueDef ]


{-| The definition of `applyStaged : (Int -> Int -> Int) -> Int -> Int -> Int`.
Its else branch calls `f` with two arguments, `10` and a recursive call, so
the recursive call is not in tail position.
-}
applyStagedDef : TypedDef
applyStagedDef =
    { name = "applyStaged"
    , args = [ pVar "f", pVar "n", pVar "acc" ]
    , tipe = tLambda (tLambda intT int1T) (tLambda intT (tLambda intT intT))
    , body =
        ifExpr
            (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
            (varExpr "acc")
            (callExpr (varExpr "f")
                [ intExpr 10
                , callExpr (varExpr "applyStaged")
                    [ varExpr "f"
                    , binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1)
                    , varExpr "acc"
                    ]
                ]
            )
    }


{-| The definition of `testValue : Int`, which calls `applyStaged` with the
curried lambda `\a -> \b -> a * 10 + b`, then `2` and `3`.
-}
testValueDef : TypedDef
testValueDef =
    { name = "testValue"
    , args = []
    , tipe = intT
    , body =
        callExpr (varExpr "applyStaged")
            [ lambdaExpr [ pVar "a" ]
                (lambdaExpr [ pVar "b" ]
                    (binopsExpr
                        [ ( binopsExpr [ ( varExpr "a", "*" ) ] (intExpr 10), "+" ) ]
                        (varExpr "b")
                    )
                )
            , intExpr 2
            , intExpr 3
            ]
    }



-- GRAPH WALK ----------------------------------------------------------------


{-| Returns whether any node of the graph has a body containing a call for
which `isStagedStampedCall` holds. Empty node slots and nodes with no body
expression contribute nothing.
-}
hasStagedStamp : Mono.MonoGraph -> Bool
hasStagedStamp (Mono.MonoGraph data) =
    Array.foldl
        (\mn found ->
            found
                || List.any
                    (\e -> MonoTraverse.foldExpr (\sub acc -> acc || isStagedStampedCall sub) False e)
                    (nodeExprs mn)
        )
        False
        data.nodes


{-| Returns whether `e` is a call whose `CallInfo` has a `fastEvaluator` and a
`captureAbi`, and which has more arguments than that `captureAbi`'s
`paramTypes`: the shape of a staged stamp. Any other expression, including a
call missing either field, gives `False`.
-}
isStagedStampedCall : Mono.MonoExpr -> Bool
isStagedStampedCall e =
    case e of
        Mono.MonoCall _ _ args _ callInfo ->
            case ( callInfo.fastEvaluator, callInfo.captureAbi ) of
                ( Just _, Just abi ) ->
                    List.length args > List.length abi.paramTypes

                _ ->
                    False

        _ ->
            False


{-| Returns the body expression of a node slot: one for a define, a tail
function or a port, and none for an empty slot or any other node.
-}
nodeExprs : Maybe Mono.MonoNode -> List Mono.MonoExpr
nodeExprs maybeNode =
    case maybeNode of
        Just (Mono.MonoDefine e _) ->
            [ e ]

        Just (Mono.MonoTailFunc _ e _) ->
            [ e ]

        Just (Mono.MonoPortIncoming e _) ->
            [ e ]

        Just (Mono.MonoPortOutgoing e _) ->
            [ e ]

        _ ->
            []
