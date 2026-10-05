module TestLogic.Monomorphize.LssVarSuccTest exposing (suite)

{-| Checks that a partially applied function passed to a higher-order function
reaches that function's parameter with a known lambda set on both of the
parameter's arrows. Without it, a change that left the inner arrow of such a
parameter without a lambda set would go unnoticed.

Under lambda-set specialization (LSS), each function arrow in a `MonoType`
carries a `LambdaSetAnno`: the function values, called members, that can flow
through that arrow. `LSet` lists the members, and `LVar` marks a slot that
nothing has written; `Compiler.AST.Monomorphized` describes the other forms.
Partially applying a global `X` to `k` arguments makes a member of its own,
whose key is `p|X|k`. A parameter of type `x -> Int -> Int` has two arrows:
its head, taking the `x`, and the result arrow `Int -> Int` inside it. The
first parameter is written `/a0` and the result arrow inside it `/a0/r`.

The module is named for `settleVarSuccessors` in
`Compiler.MonoSolver.Monomorphize`, a pass that can fill an `LVar` result
arrow under an `LSet` arrow with partial-application successors of that
arrow's members, and does so only when every member has such a successor
within its global's declared arity. It writes only into an `LVar` slot, and
on this fixture both arrows already hold sets before it runs, so it writes
nothing here: making it the identity leaves the test passing. The test checks
the end state the solver reaches on its fixture, whichever stage wrote it.

The fixture is a module `Test` with three annotated definitions:

  - `add3 a b c = a + b + c`, of type `Int -> Int -> Int -> Int`.
  - `useStep g seed = g seed 2`, of type `(x -> Int -> Int) -> x -> Int`,
    polymorphic in `x`.
  - `testValue = useStep (add3 1) 5`, which passes `add3` applied to one
    argument as `useStep`'s first parameter.

It is run through the MonoSolver engine with `Config.defaultLimits` and
`Config.defaultLss` with LSS switched on. The output graph's registry has a row
for each specialization it keeps, naming the global and the `MonoType` recorded
for it.

What the tests establish:

  - Test 1: the pipeline succeeds; at least one registry row for `useStep`
    has a first parameter that is a one-parameter arrow returning an arrow;
    and in every such row the `/a0` annotation is the singleton `p|add3|1`
    and the `/a0/r` annotation the singleton `p|add3|2`, as the graph's
    `lssMemberOrigins` records them.

Among what is not tested:

  - a fixture in which `/a0/r` is still `LVar` before `settleVarSuccessors`
    runs, so the pass's own writes are not exercised;
  - registry rows for `useStep` of any other shape, which are skipped rather
    than failed.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , intExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pVar
        , tLambda
        , tType
        , tVar
        , varExpr
        )
import Compiler.Eco.Config as Config
import Dict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The test that the fixture's `useStep` rows carry `add3`'s
partial-application members at both `/a0` and `/a0/r`.
-}
suite : Test
suite =
    Test.describe "PAP successor coverage at a HOF parameter (end state)"
        [ Test.test "1. the fixture is fully covered at the useStep /a0 spine" <|
            \() ->
                case runWith fixture of
                    Ok g ->
                        case stepAnnos g of
                            [] ->
                                Expect.fail "no useStep /a0 arrow-result position — fixture broken"

                            a ->
                                if List.all (\( h, r ) -> isPapSingleton "add3" 1 g h && isPapSingleton "add3" 2 g r) a then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("expected p|add3|1 at /a0 and p|add3|2 at /a0/r (in-item transport regressed?): "
                                            ++ describePairs a
                                        )

                    Err e ->
                        Expect.fail e
        ]



-- ====== FIXTURE ======


{-| The source type `Int`, used for every `Int` in the fixture's annotations.
-}
hInt : Src.Type
hInt =
    tType "Int" []


{-| The module `Test` holding `add3`, `useStep` and `testValue`, as the module
docstring describes them.
-}
fixture : Src.Module
fixture =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ { name = "add3"
          , args = [ pVar "a", pVar "b", pVar "c" ]
          , tipe = tLambda hInt (tLambda hInt (tLambda hInt hInt))
          , body =
                binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c")
          }
        , { name = "useStep"
          , args = [ pVar "g", pVar "seed" ]
          , tipe = tLambda (tLambda (tVar "x") (tLambda hInt hInt)) (tLambda (tVar "x") hInt)
          , body = callExpr (varExpr "g") [ varExpr "seed", intExpr 2 ]
          }
        , { name = "testValue"
          , args = []
          , tipe = hInt
          , body = callExpr (varExpr "useStep") [ callExpr (varExpr "add3") [ intExpr 1 ], intExpr 5 ]
          }
        ]
        []
        []



-- ====== HARNESS ======


{-| Returns the graph the MonoSolver engine produces for `srcModule`, with the
default specialization limits and the default LSS configuration with LSS
switched on, or the pipeline's error message.
-}
runWith : Src.Module -> Result String Mono.MonoGraph
runWith srcModule =
    let
        defaults =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithLimits Config.defaultLimits
        { defaults | enabled = True }
        srcModule



-- ====== READERS ======


{-| Returns, for each registry row of a global named `useStep`, the `/a0`
annotation and the `/a0/r` annotation of its first parameter.

A row contributes only when its type is a function whose first parameter is a
one-parameter arrow returning another arrow; any other row is skipped.

-}
stepAnnos : Mono.MonoGraph -> List ( Mono.LambdaSetAnno, Mono.LambdaSetAnno )
stepAnnos (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ name, monoType ) ->
                    if name == "useStep" then
                        case monoType of
                            Mono.MFunction _ _ ((Mono.MFunction _ headA [ _ ] (Mono.MFunction _ succA _ _)) :: _) _ ->
                                ( headA, succA ) :: acc

                            _ ->
                                acc

                    else
                        acc

                _ ->
                    acc
        )
        []
        g.registry.reverseMapping


{-| Returns whether an annotation is an `LSet` whose one member the graph's
`lssMemberOrigins` records as the global named `name` applied to `supplied`
arguments.
-}
isPapSingleton : String -> Int -> Mono.MonoGraph -> Mono.LambdaSetAnno -> Bool
isPapSingleton name supplied (Mono.MonoGraph g) a =
    case a of
        Mono.LSet [ m ] ->
            case Dict.get m g.lssMemberOrigins of
                Just (Mono.OriginPap (Mono.Global _ n) k) ->
                    n == name && k == supplied

                _ ->
                    False

        _ ->
            False


{-| Renders `(/a0, /a0/r)` annotation pairs as a bracketed, comma-separated
list of `(head -> result)` entries, for a failure message.
-}
describePairs : List ( Mono.LambdaSetAnno, Mono.LambdaSetAnno ) -> String
describePairs pairs =
    "["
        ++ String.join ", "
            (List.map (\( h, r ) -> "(" ++ describeAnno h ++ " -> " ++ describeAnno r ++ ")") pairs)
        ++ "]"


{-| Renders an annotation as its constructor name followed by the top kind's
label for an `LTop`, the variable number for an `LVar`, or the member count,
not the members, for an `LSet` or an `LPartial`.
-}
describeAnno : Mono.LambdaSetAnno -> String
describeAnno a =
    case a of
        Mono.LTop k ->
            "LTop " ++ Mono.topKindLabel k

        Mono.LVar n ->
            "LVar " ++ String.fromInt n

        Mono.LSet ms ->
            "LSet " ++ String.fromInt (List.length ms)

        Mono.LPartial ms ->
            "LPartial " ++ String.fromInt (List.length ms)
