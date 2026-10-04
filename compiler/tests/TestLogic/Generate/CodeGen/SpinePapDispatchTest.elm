module TestLogic.Generate.CodeGen.SpinePapDispatchTest exposing (suite)

{-| Checks, on one compiled program, that a lambda's identity survives being
partially applied, so that a later call through the partial application is
stamped for fast dispatch. The identity reaches that call in three steps, and
a step that drops it leaves the call unstamped; these tests look for the
evidence of each step in the optimized graph.

A _lambda set_ is the annotation on each arrow of a monomorphized function
type that says which functions a value at that arrow can be;
`Mono.LambdaSetAnno` owns its meaning. Here a _singleton_ set, an `LSet` with
one member, says the value is known to be that one function. The _head_ set of
a function type is the one on its outermost arrow.

The fixture, written as Elm source:

    applyPartial : (Int -> Int -> Int) -> Int -> Int -> Int
    applyPartial f n acc =
        if n <= 0 then
            acc

        else
            let
                g =
                    f 10
            in
            applyPartial f (n - 1) (g acc + g 1)

    testValue : Int
    testValue =
        let
            step =
                7
        in
        applyPartial (\a b -> a * 100 + b * 10 + step) 2 3

`applyPartial` calls itself, and the post-monomorphization inliner
(`Compiler.GlobalOpt.MonoInlineSimplify`) does not inline a recursive
specialization. Nor does it copy `applyPartial`'s body into the caller
(loopification), because the only call of `f` in that body is the partial
application `f 10`. So `f` stays a parameter that receives the lambda. The
lambda takes two parameters and refers to `step`, which is bound outside it.
`g` is a partial application of `f` to one argument, and is called twice.

The three steps are rules of `Compiler.MonoSolver`:

1.  _Spine injection_ puts a lambda literal's member on as many arrows of its
    type as it has parameters, not only on the head: here on both arrows of
    `Int -> Int -> Int`.
2.  _Call-result transport_ gives the result of a call through a function
    value the lambda sets of the callee's type left after peeling one parameter
    per argument. With step 1, this puts the lambda's member on the head of `g`,
    the result of `f 10`.
3.  _Local-multi use transport_ applies to a `let` that binds a
    non-tail-recursive function, such as `g`. Such a `let` is specialized once
    for each type it is used at, and its uses are translated before those
    specializations exist; afterwards the lambda sets of the specialized
    definition are copied onto the uses. This gives the callee `g` in `g acc`
    and `g 1` its singleton head.

The stamp is set by `Compiler.GlobalOpt.AbiCloning`, which can stamp a call
whose callee it identifies as a partial application holding `k` arguments
with `fastPapPrefix = Just k` in its `Mono.CallInfo`, whose docstring owns the
field's meaning. For `g acc` and `g 1`, `k` is 1.

The tests run the fixture through `Pipeline.runToGlobalOptLssOn` and inspect
its `optimizedMonoGraph`, which has been through `AbiCloning`. Each assertion
asks whether any expression anywhere in the graph matches, not whether a
particular call does.

  - The let-binding test checks that some `let` (not a tail-recursive local
    definition) has a right-hand side whose type is a function with a
    singleton head set. The only function-typed `let` the fixture writes is
    `g`, so this is the evidence of steps 1 and 2.
  - The use-site test checks that some call's callee is a local variable whose
    type is a function with a singleton head set and a result type that is not
    a function. It is aimed at step 3: the result condition is there to leave
    out `f 10`, whose result is a function while `f`'s type keeps its curried
    form.
  - The stamp test checks that some call carries `fastPapPrefix == Just 1`.

Among what is not tested: which expression satisfies each assertion, or that
it is the same call for the second and third; that the singleton's member is the
lambda's, since any one-member set passes; the stamp's other fields; the MLIR
generated for the call; and the value `testValue` computes.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , callExpr
        , define
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
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


{-| The three tests, one per assertion on the optimized graph of the fixture.
-}
suite : Test
suite =
    Test.describe "LSS_013 spine + E4a use transport activate PAP fast dispatch"
        [ Test.test "a partial-application let-binding carries a singleton lambda set (spine + call-result transport)" <|
            \_ ->
                expectOnGraph hasSingletonFnLetDef
                    "no function-typed let-binding carries a singleton LSet — spine injection + call-result transport did not reach `let g = f 10`"
        , Test.test "a use-site callee carries the singleton lambda set (E4a local-multi use transport)" <|
            \_ ->
                expectOnGraph hasSingletonCalleeUse
                    "no call's MonoVarLocal callee carries a singleton LSet head — E4a did not transport the def's set to the use sites"
        , Test.test "the PAP-consuming call is StampPap'd (fastPapPrefix = Just 1)" <|
            \_ ->
                expectOnGraph hasPapPrefixStamp
                    "no call carries callInfo.fastPapPrefix == Just 1 — the E2 StampPap did not fire on `g acc`"
        ]


{-| Runs the fixture through `Pipeline.runToGlobalOptLssOn` and passes when
`predicate` holds of the optimized graph. It fails with `failureMsg` when the
predicate does not hold. When `Pipeline.runToGlobalOptLssOn` returns an error,
it fails with that error's text, prefixed by `solver+LSS pipeline failed:` and a space.
-}
expectOnGraph : (Mono.MonoGraph -> Bool) -> String -> Expect.Expectation
expectOnGraph predicate failureMsg =
    case Pipeline.runToGlobalOptLssOn fixtureModule of
        Err e ->
            Expect.fail ("solver+LSS pipeline failed: " ++ e)

        Ok { optimizedMonoGraph } ->
            if predicate optimizedMonoGraph then
                Expect.pass

            else
                Expect.fail failureMsg



-- FIXTURE (DSL) -------------------------------------------------------------


{-| The source type `Int`.
-}
intT : Src.Type
intT =
    tType "Int" []


{-| The source type `Int -> Int`, the type of `g`.
-}
int1T : Src.Type
int1T =
    tLambda intT intT


{-| The source type `Int -> Int -> Int`, the type of the lambda and of `f`.
-}
int2T : Src.Type
int2T =
    tLambda intT int1T


{-| The fixture: a module named `Test` holding `applyPartial` and `testValue`,
as the module docstring writes them.
-}
fixtureModule : Src.Module
fixtureModule =
    makeModuleWithTypedDefs "Test" [ applyPartialDef, testValueDef ]


{-| The definition of `applyPartial`, annotated
`(Int -> Int -> Int) -> Int -> Int -> Int`. It counts `n` down to 0, and on
each step binds `g = f 10` and passes `g acc + g 1` as the new `acc`.
-}
applyPartialDef : TypedDef
applyPartialDef =
    { name = "applyPartial"
    , args = [ pVar "f", pVar "n", pVar "acc" ]
    , tipe = tLambda int2T (tLambda intT (tLambda intT intT))
    , body =
        ifExpr
            (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
            (varExpr "acc")
            (letExpr
                [ define "g" [] (callExpr (varExpr "f") [ intExpr 10 ]) ]
                (callExpr (varExpr "applyPartial")
                    [ varExpr "f"
                    , binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1)
                    , binopsExpr
                        [ ( callExpr (varExpr "g") [ varExpr "acc" ], "+" ) ]
                        (callExpr (varExpr "g") [ intExpr 1 ])
                    ]
                )
            )
    }


{-| The definition of `testValue : Int`, which binds `step` to 7 and calls
`applyPartial` with a two-parameter lambda that adds `a * 100`, `b * 10` and
`step`, with `n` 2 and `acc` 3.
-}
testValueDef : TypedDef
testValueDef =
    { name = "testValue"
    , args = []
    , tipe = intT
    , body =
        letExpr
            [ define "step" [] (intExpr 7) ]
            (callExpr (varExpr "applyPartial")
                [ lambdaExpr [ pVar "a", pVar "b" ]
                    (binopsExpr
                        [ ( binopsExpr [ ( varExpr "a", "*" ) ] (intExpr 100), "+" )
                        , ( binopsExpr [ ( varExpr "b", "*" ) ] (intExpr 10), "+" )
                        ]
                        (varExpr "step")
                    )
                , intExpr 2
                , intExpr 3
                ]
            )
    }



-- GRAPH WALKS ---------------------------------------------------------------


{-| Returns whether `predicate` holds of some expression, at any depth, in the
body of some node of the graph.
-}
anyGraphExpr : (Mono.MonoExpr -> Bool) -> Mono.MonoGraph -> Bool
anyGraphExpr predicate (Mono.MonoGraph data) =
    Array.foldl
        (\mn found ->
            found
                || List.any
                    (\e -> MonoTraverse.foldExpr (\sub acc -> acc || predicate sub) False e)
                    (nodeExprs mn)
        )
        False
        data.nodes


{-| Returns the body of a node that has one: a define, a tail-recursive
function or a port. Other nodes, and an empty slot, give no expressions.
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


{-| Returns whether some `let` in the graph binds, with a non-tail definition,
a right-hand side whose type is a function with a singleton head set.
-}
hasSingletonFnLetDef : Mono.MonoGraph -> Bool
hasSingletonFnLetDef =
    anyGraphExpr
        (\e ->
            case e of
                Mono.MonoLet (Mono.MonoDef _ rhs) _ _ ->
                    isSingletonFn (Mono.typeOf rhs)

                _ ->
                    False
        )


{-| Returns whether some call in the graph has as its callee a local variable
whose type is a function with a singleton head set and a result that is not a
function.

The result condition leaves out a call such as `f 10`, whose callee's result is
itself a function while the callee's type is curried, so that, in this
fixture, the match is a use of `g` rather than the call that defines it.

-}
hasSingletonCalleeUse : Mono.MonoGraph -> Bool
hasSingletonCalleeUse =
    anyGraphExpr
        (\e ->
            case e of
                Mono.MonoCall _ (Mono.MonoVarLocal _ t) _ _ _ ->
                    case t of
                        Mono.MFunction _ (Mono.LSet [ _ ]) _ ret ->
                            not (isFn ret)

                        _ ->
                            False

                _ ->
                    False
        )


{-| Returns whether some call in the graph carries `fastPapPrefix = Just 1`,
the stamp for a callee known to be a partial application holding one argument.
-}
hasPapPrefixStamp : Mono.MonoGraph -> Bool
hasPapPrefixStamp =
    anyGraphExpr
        (\e ->
            case e of
                Mono.MonoCall _ _ _ _ callInfo ->
                    callInfo.fastPapPrefix == Just 1

                _ ->
                    False
        )


{-| Returns whether a type is a function whose head lambda set has exactly one
member.
-}
isSingletonFn : Mono.MonoType -> Bool
isSingletonFn t =
    case t of
        Mono.MFunction _ (Mono.LSet [ _ ]) _ _ ->
            True

        _ ->
            False


{-| Returns whether a type is a function type.
-}
isFn : Mono.MonoType -> Bool
isFn t =
    case t of
        Mono.MFunction _ _ _ _ ->
            True

        _ ->
            False
