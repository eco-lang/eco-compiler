module TestLogic.Generate.CodeGen.E9CtorDevirtTest exposing (suite)

{-| Checks that, for a fixture in which a constructor is passed as a function
value, no call through a local variable is left in the optimized graph, in
particular at the place where that function value is applied.

The rewrite under test is _devirtualization_. A function-typed value carries a
_lambda set_, the set of functions it can be at run time, which the solver
engine's lambda-set specialization (LSS) works out. Devirtualization replaces a
call through a variable by a direct call to the one function the variable can
be. Among the conditions for it are that the variable's lambda set has exactly
one member and that the call supplies exactly as many arguments as that member
takes. Without this test, a constructor passed as an argument could be reached
through an indirect call even though it is known statically.

The fixture is one module, `Test`, built with `Compiler.AST.SourceBuilder` and
written here as Elm source:

    type Pair
        = P Int Int
        | Q

    applyP : (Int -> Int -> Pair) -> Int -> Pair
    applyP f n =
        if n <= 0 then
            f (n + 3) (n + 4)

        else
            applyP f (n - 1)

    testValue : Int
    testValue =
        case applyP P 2 of
            P a b ->
                a + b

            Q ->
                0 - 1

`Pair` has two constructors and one of them has fields, so `P` is an ordinary
constructor (`Can.Normal`), neither an enum nor an unboxed wrapper. The only
value ever passed as `f` is `P`, and `f (n + 3) (n + 4)` gives it both of its
arguments. The pipeline adds a `main` that uses `testValue`, as
`TestLogic.TestPipeline` describes, and that is what makes `applyP` reachable.

What the test establishes:

  - The fixture goes through `TestLogic.TestPipeline.runToGlobalOptLssOn`
    (solver engine, LSS on) without an error, and afterwards no expression in
    any node of the optimized graph is a `MonoCall` whose callee is a
    `MonoVarLocal`.

Among what is not tested:

  - That a direct call to `P` exists. The assertion also passes if the call
    through `f` is removed some other way.
  - A constructor applied to fewer arguments than it takes.
  - Anything after global optimization, such as the code generated for the
    call.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , ifExpr
        , intExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pCtor
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The suite: the one test the module docstring describes.
-}
suite : Test
suite =
    Test.describe "E9: ctor passed as function devirtualizes to a direct call"
        [ Test.test "no VarLocal-callee call remains (the f-site became a direct ctor call)" <|
            \_ ->
                case Pipeline.runToGlobalOptLssOn fixtureModule of
                    Err e ->
                        Expect.fail ("solver+LSS pipeline failed: " ++ e)

                    Ok { optimizedMonoGraph } ->
                        case indirectCallCount optimizedMonoGraph of
                            0 ->
                                Expect.pass

                            n ->
                                Expect.fail
                                    (String.fromInt n
                                        ++ " VarLocal-callee call(s) remain — E9 did not devirtualize `f (n+3) (n+4)`"
                                    )
        ]



-- FIXTURE (DSL) -------------------------------------------------------------


{-| The type `Int`, as it is written in a type annotation.
-}
intT : Src.Type
intT =
    tType "Int" []


{-| The fixture's own type `Pair`, as it is written in a type annotation.
-}
pairT : Src.Type
pairT =
    tType "Pair" []


{-| The fixture module `Test`: the union type `Pair` and the annotated
definitions of `applyP` and `testValue`.
-}
fixtureModule : Src.Module
fixtureModule =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ applyPDef, testValueDef ]
        [ { name = "Pair"
          , args = []
          , ctors =
                [ { name = "P", args = [ intT, intT ] }
                , { name = "Q", args = [] }
                ]
          }
        ]
        []


{-| The definition of `applyP`, annotated `(Int -> Int -> Pair) -> Int -> Pair`.
When `n` is at most 0 it calls its function argument `f` with `n + 3` and
`n + 4`; otherwise it calls itself with `f` and `n - 1`.
-}
applyPDef : TypedDef
applyPDef =
    { name = "applyP"
    , args = [ pVar "f", pVar "n" ]
    , tipe = tLambda (tLambda intT (tLambda intT pairT)) (tLambda intT pairT)
    , body =
        ifExpr
            (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
            (callExpr (varExpr "f")
                [ binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 3)
                , binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 4)
                ]
            )
            (callExpr (varExpr "applyP")
                [ varExpr "f"
                , binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1)
                ]
            )
    }


{-| The definition of `testValue`, annotated `Int`: a `case` on `applyP P 2`
that gives `a + b` for `P a b` and `0 - 1` for `Q`. Passing `P` here is what
makes it the one member of `f`'s lambda set.
-}
testValueDef : TypedDef
testValueDef =
    { name = "testValue"
    , args = []
    , tipe = intT
    , body =
        caseExpr (callExpr (varExpr "applyP") [ ctorExpr "P", intExpr 2 ])
            [ ( pCtor "P" [ pVar "a", pVar "b" ]
              , binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
              )
            , ( pCtor "Q" []
              , binopsExpr [ ( intExpr 0, "-" ) ] (intExpr 1)
              )
            ]
    }



-- GRAPH WALK ----------------------------------------------------------------


{-| Counts the calls in the graph whose callee is a local variable, over every
expression of every node.
-}
indirectCallCount : Mono.MonoGraph -> Int
indirectCallCount (Mono.MonoGraph data) =
    Array.foldl
        (\mn acc ->
            List.foldl
                (\e a -> MonoTraverse.foldExpr countIndirect a e)
                acc
                (nodeExprs mn)
        )
        0
        data.nodes


{-| Returns `acc` plus one when `e` itself is a call whose callee is a local
variable, and `acc` otherwise. It does not look inside `e`;
`indirectCallCount` folds it over every subexpression.
-}
countIndirect : Mono.MonoExpr -> Int -> Int
countIndirect e acc =
    case e of
        Mono.MonoCall _ (Mono.MonoVarLocal _ _) _ _ _ ->
            acc + 1

        _ ->
            acc


{-| Returns the expression a graph node holds: the body of a definition or of a
tail-recursive function, or the expression of a port. A constructor, enum,
extern or manager-leaf node holds none, and neither does an empty slot.
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
