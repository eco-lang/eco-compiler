module TestLogic.Generate.CodeGen.E92ConsDevirtTest exposing (suite)

{-| Checks that the solver engine turns a call through a function parameter
into a direct call of the `List.cons` kernel when `(::)` is the only function
that can reach that parameter. If that rewrite stopped happening, the call
would stay an indirect call through a closure. The solver engine is one of
the compiler's two monomorphizers; the other is the substitution engine.

With lambda-set specialization on, the solver engine records on each function
type the set of function values that can flow there, its _lambda set_.
_Devirtualization_ replaces a call through a variable whose lambda set has a
single member by a direct call of that member. For a kernel member,
`Compiler.MonoSolver.Translate` does this only for a kernel that
`Compiler.GlobalOpt.KernelFacts` registers, at a call that supplies exactly
the registered number of arguments, and only when no residual `number` type
variable appears in the call's types. `List.cons` is registered with two
arguments, and its tail and result must not be an unboxed scalar.

The fixture is the module `Test`:

    applyCons : (Int -> List Int -> List Int) -> Int -> List Int
    applyCons f n =
        if n <= 0 then
            f (n + 3) []

        else
            applyCons f (n - 1)

    testValue : List Int
    testValue =
        applyCons (::) 2

`(::)` passed as a value is a reference to `List.cons`, which the test
pipeline defines as an alias of the kernel `Elm.Kernel.List.cons`, so that
kernel is the only member reaching `f`, and `f (n + 3) []` gives it both its
arguments. The annotations fix every number at `Int`, and the tail and result
are lists. Because `applyCons` is recursive, the post-monomorphization
inliner does not take it as an ordinary inline candidate.

The one test runs the fixture through
`TestLogic.TestPipeline.runToGlobalOptLssOn` and reads every expression of the
optimized graph:

  - It fails if the pipeline returns an error.
  - It fails if any call has a local variable as its callee. The failure
    message lists each such callee with its head lambda set, and the keys of
    the typed global graph that contain `cons`.
  - Otherwise it fails if no call has the `List.cons` kernel as its callee, so
    a run in which the call through `f` disappeared and no `List.cons` kernel
    call took its place does not pass.

Among what is not tested: that the `List.cons` call found is the one at
`f (n + 3) []`, since a call anywhere in the graph counts; a call that gives
`f` fewer or more than two arguments; any kernel other than `List.cons`; and
the substitution engine.

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
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , opExpr
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Data.Map
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The test that runs the fixture through the solver pipeline and checks
that the call through `f` became a direct `List.cons` kernel call, as the
module docstring describes.
-}
suite : Test
suite =
    Test.describe "E9.2: (::) passed as function devirtualizes to a direct kernel call"
        [ Test.test "the f-site became a direct List.cons kernel call" <|
            \_ ->
                case Pipeline.runToGlobalOptLssOn fixtureModule of
                    Err e ->
                        Expect.fail ("solver+LSS pipeline failed: " ++ e)

                    Ok { optimizedMonoGraph, globalGraph } ->
                        case ( indirectCallCount optimizedMonoGraph, kernelConsCallCount optimizedMonoGraph ) of
                            ( 0, 0 ) ->
                                Expect.fail "no VarLocal-callee call remains, but no List.cons kernel call either — the site vanished instead of devirtualizing"

                            ( 0, _ ) ->
                                Expect.pass

                            ( n, _ ) ->
                                Expect.fail
                                    (String.fromInt n
                                        ++ " VarLocal-callee call(s) remain — E9.2 did not devirtualize `f (n+3) []`; callee annos: "
                                        ++ String.join ", " (indirectCalleeAnnos optimizedMonoGraph)
                                        ++ "; cons node keys: "
                                        ++ String.join " | " (consNodeKeys globalGraph)
                                    )
        ]



-- FIXTURE (DSL) -------------------------------------------------------------


{-| The source type `Int`, as the fixture's annotations write it.
-}
intT : Src.Type
intT =
    tType "Int" []


{-| The source type `List Int`, as the fixture's annotations write it.
-}
listIntT : Src.Type
listIntT =
    tType "List" [ intT ]


{-| The fixture module `Test`, holding the annotated definitions of
`applyCons` and `testValue` and no custom types or aliases.
-}
fixtureModule : Src.Module
fixtureModule =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ applyConsDef, testValueDef ]
        []
        []


{-| The definition of `applyCons`, annotated
`(Int -> List Int -> List Int) -> Int -> List Int`. Once `n` is zero or
below it calls its parameter `f` with `n + 3` and `[]`; otherwise it calls
itself with `n - 1`.
-}
applyConsDef : TypedDef
applyConsDef =
    { name = "applyCons"
    , args = [ pVar "f", pVar "n" ]
    , tipe = tLambda (tLambda intT (tLambda listIntT listIntT)) (tLambda intT listIntT)
    , body =
        ifExpr
            (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
            (callExpr (varExpr "f")
                [ binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 3)
                , listExpr []
                ]
            )
            (callExpr (varExpr "applyCons")
                [ varExpr "f"
                , binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1)
                ]
            )
    }


{-| The definition `testValue = applyCons (::) 2`, annotated `List Int`. Its
`(::)` is the only function value that reaches `applyCons`'s parameter `f`.
-}
testValueDef : TypedDef
testValueDef =
    { name = "testValue"
    , args = []
    , tipe = listIntT
    , body = callExpr (varExpr "applyCons") [ opExpr "::", intExpr 2 ]
    }



-- GRAPH WALK ----------------------------------------------------------------


{-| Counts the calls in the graph whose callee is a local variable, over the
expressions of every node.
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


{-| Adds one to `acc` when `e` is a call whose callee is a local variable.
-}
countIndirect : Mono.MonoExpr -> Int -> Int
countIndirect e acc =
    case e of
        Mono.MonoCall _ (Mono.MonoVarLocal _ _) _ _ _ ->
            acc + 1

        _ ->
            acc


{-| Returns, for each call in the graph whose callee is a local variable, the
variable's name and the head lambda set of its type, as `name:anno`. Only the
failure message uses it.
-}
indirectCalleeAnnos : Mono.MonoGraph -> List String
indirectCalleeAnnos (Mono.MonoGraph data) =
    Array.foldl
        (\mn acc ->
            List.foldl
                (\e a -> MonoTraverse.foldExpr collectCalleeAnno a e)
                acc
                (nodeExprs mn)
        )
        []
        data.nodes


{-| Adds `name:anno` to `acc` when `e` is a call through the local variable
`name`, where `anno` is the head lambda set of the variable's type as
`renderAnno` writes it.
-}
collectCalleeAnno : Mono.MonoExpr -> List String -> List String
collectCalleeAnno e acc =
    case e of
        Mono.MonoCall _ (Mono.MonoVarLocal name t) _ _ _ ->
            (name ++ ":" ++ renderAnno (Mono.headAnno t)) :: acc

        _ ->
            acc


{-| Returns the key, as `TOpt.toComparableGlobal` writes it, of every node in
the typed global graph whose key contains `cons`. It shows whether the test
pipeline's `List.cons` kernel alias is in the graph, and under which key. Only
the failure message uses it.
-}
consNodeKeys : TOpt.GlobalGraph n -> List String
consNodeKeys (TOpt.GlobalGraph nodes _ _ _ _) =
    Data.Map.foldl (\_ _ -> EQ) (\g _ acc -> TOpt.toComparableGlobal g :: acc) [] nodes
        |> List.filter (String.contains "cons")


{-| Writes a lambda-set annotation as short text: `LTop` without its
provenance code, `LVar` followed by its number, or `LSet` or `LPartial`
followed by the member ids in brackets.
-}
renderAnno : Mono.LambdaSetAnno -> String
renderAnno anno =
    case anno of
        Mono.LTop _ ->
            "LTop"

        Mono.LVar n ->
            "LVar" ++ String.fromInt n

        Mono.LSet ms ->
            "LSet[" ++ String.join "," (List.map String.fromInt ms) ++ "]"

        Mono.LPartial ms ->
            "LPartial[" ++ String.join "," (List.map String.fromInt ms) ++ "]"


{-| Counts the calls in the graph whose callee is the `List.cons` kernel, with
either kernel prefix, over the expressions of every node.
-}
kernelConsCallCount : Mono.MonoGraph -> Int
kernelConsCallCount (Mono.MonoGraph data) =
    Array.foldl
        (\mn acc ->
            List.foldl
                (\e a -> MonoTraverse.foldExpr countKernelCons a e)
                acc
                (nodeExprs mn)
        )
        0
        data.nodes


{-| Adds one to `acc` when `e` is a call whose callee is the `List.cons`
kernel.
-}
countKernelCons : Mono.MonoExpr -> Int -> Int
countKernelCons e acc =
    case e of
        Mono.MonoCall _ (Mono.MonoVarKernel _ _ home name _) _ _ _ ->
            if home == "List" && name == "cons" then
                acc + 1

            else
                acc

        _ ->
            acc


{-| Returns the expression a node holds: the body of a definition or of a
tail-recursive function, or a port's expression. Every other kind of node,
and an empty slot, gives none.
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
