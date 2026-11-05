module Compiler.Monomorphize.Solver.LssPapMembersTest exposing (suite)

{-| Checks, on three small programs, that when a partial application of a
top-level function is passed to another function, the lambda-set solver does
not describe the receiving position as holding fewer functions than it can.

A _lambda set_ is the annotation on an arrow of a monomorphized type
(`Compiler.IR.Mono.LambdaSetAnno`) that says which functions, its
_members_, can arrive at that position. `LSet` lists them, `LPartial` lists
some of them as a lower bound, and `LTop` and `LVar` name none. A singleton
`LSet` is the one form a later pass may read as "the function here is this
one" (`Compiler.IR.Mono.singletonHeadMember`), so a singleton that
leaves out a function which really arrives can make a wrong program, not
merely a slow one. Call such a set _falsely complete_.

`addTo 7`, where `addTo` takes two parameters, is a _partial application_: a
function value of type `Int -> Int` that is not the same function as `addTo`.
The solver gives it its own member, distinct from `addTo`'s
(`Compiler.Monomorphize.Solver.Engine.papMemberIdFor`). That member is registered as a
partial application, not a global, so the solver's direct-call rewrite never
targets it (`Compiler.Monomorphize.Solver.Engine.standaloneMemberGlobal`).

The fixtures are three modules built with `makeModuleWithTypedDefs`. Each
defines `addTo a b = a + b` at `Int -> Int -> Int`, and its `testValue` passes
a function value built from `addTo 7` to another function:

  - `joinModule` passes `if True then addTo 7 else idf`, with `idf x = x`, to
    `useIt f = f 1`;
  - `loneModule` passes `addTo 7` alone to the same `useIt`;
  - `papDevirtModule` passes `addTo 7` to `applyTwice f n = f (f n)`, which
    calls it twice.

Each is run through `TestLogic.TestPipeline` to a monomorphized graph with the
solver engine and the default lambda-set configuration (`runWith`).
Annotations are read from the demand types the graph's registry holds for each
specialization. For `useIt` the outermost arrow's annotation is skipped,
because the solver stamps `useIt`'s own member there wherever the annotation
is not already an `LSet` (`allAnnos`), so what is read is `useIt`'s parameter
and the arrows inside it.

The tests:

  - Test 1 finds at least one annotation below `useIt`'s outermost arrow in
    `joinModule`'s graph, and checks that each is `LTop`, `LVar`, `LPartial`
    or an `LSet` of two or more members, never a singleton or empty `LSet`.
    Widening the position to `LTop` passes this test.
  - Test 2 checks that `useIt` has at least one demand in `loneModule`'s
    graph and that the head arrow of its parameter is, in every one, a
    singleton `LSet` whose member `lssMemberOrigins` records as `OriginPap`
    of `addTo` with one argument supplied. Widening to `LTop` fails it.
  - Test 4 checks the same of `applyTwice`'s parameter in
    `papDevirtModule`'s graph, so `addTo`'s own `g|` member there fails it.
  - Test 5 applies `TestLogic.Monomorphize.LambdaSetWellFormed.lambdaSetIssues`
    (LSS\_001) to the graphs of all three fixtures: no annotation in a registry
    demand type, a node type or an expression type is the empty `LSet`, and
    every member list is strictly ascending; a fixture whose run fails fails
    the test. The same check runs over the standard catalogue, after the
    production pipeline, in `TestLogic.Monomorphize.LambdaSetWellFormedTest`;
    it is kept here for these fixtures, which the catalogue does not hold.

There is no test 3.

Among what is not tested: which members test 1's sets name, only that each
has at least two; and anything after monomorphization, since global
optimization is not run.

-}

import Array
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , boolExpr
        , callExpr
        , ifExpr
        , intExpr
        , makeModuleWithTypedDefs
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import Compiler.Config as Config
import Compiler.IR.Mono as Mono
import Compiler.IR.Source as Src
import Dict
import Expect
import Test exposing (Test)
import TestLogic.Monomorphize.LambdaSetWellFormed as LambdaSetWellFormed
import TestLogic.TestPipeline as Pipeline


{-| The four tests listed in the module docstring.
-}
suite : Test
suite =
    Test.describe "injection completeness for partial applications"
        [ Test.test "1. THE CRASH SHAPE: a one-sided join is never a false singleton" <|
            \() ->
                case runWith joinModule of
                    Err msg ->
                        Expect.fail msg

                    Ok graph ->
                        case allAnnos "useIt" graph of
                            [] ->
                                Expect.fail "no demand recorded for `useIt` — fixture broken"

                            annos ->
                                if List.all neverFalselyComplete annos then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("a one-sided join must not publish a singleton, got: "
                                            ++ describeAnnos annos
                                        )
        , Test.test "2. the partial's member is PRESENT, not merely widened away" <|
            \() ->
                case runWith loneModule of
                    Err msg ->
                        Expect.fail msg

                    Ok graph ->
                        case paramHeadAnnos "useIt" graph of
                            [] ->
                                Expect.fail "no demand recorded for `useIt` — fixture broken"

                            annos ->
                                if List.all (isPapSingleton "addTo" 1 graph) annos then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("expected the injected `addTo 7` PAP member, alone, at the consumer's param, got: "
                                            ++ describeAnnos annos
                                        )
        , Test.test "4. the PAP member is NOT the callee's own `g|` identity" <|
            \() ->
                case runWith papDevirtModule of
                    Err msg ->
                        Expect.fail ("PAP member licensed a bad devirt: " ++ msg)

                    Ok graph ->
                        case paramHeadAnnos "applyTwice" graph of
                            [] ->
                                Expect.fail "no demand recorded for `applyTwice` — fixture broken"

                            annos ->
                                if List.all (isPapSingleton "addTo" 1 graph) annos then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("expected the `addTo 7` PAP member, not `addTo`'s own, at applyTwice's param, got: "
                                            ++ describeAnnos annos
                                            ++ " with origins "
                                            ++ Debug.toString (List.map (originsOf graph) annos)
                                        )
        , Test.test "5. LSS_001: injection never manufactures an EMPTY set" <|
            \() ->
                case
                    List.foldr (Result.map2 (++))
                        (Ok [])
                        (List.map (runWith >> Result.map (LambdaSetWellFormed.lambdaSetIssues "solver graph"))
                            [ joinModule, loneModule, papDevirtModule ]
                        )
                of
                    Err msg ->
                        Expect.fail msg

                    Ok [] ->
                        Expect.pass

                    Ok issues ->
                        Expect.fail (String.join "\n" issues)
        ]



-- ====== HARNESS ======


{-| Runs `srcModule` through the test pipeline and monomorphizes it with the
solver engine, under the default lambda-set configuration with `enabled` set
(already its default) and the default specialization limits. An `Err`
carries the test pipeline's error message.
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



-- ====== FIXTURES ======


{-| The source type `Int -> Int`, the type of the function values the
fixtures pass around.
-}
hInt : Src.Type
hInt =
    tLambda (tType "Int" []) (tType "Int" [])


{-| A module in which `useIt`'s parameter receives one of two function
values: `testValue` passes it `if True then addTo 7 else idf`, a partial
application in one branch and a reference to the one-parameter `idf` in the
other.
-}
joinModule : Src.Module
joinModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "addTo"
          , args = [ pVar "a", pVar "b" ]
          , tipe = tLambda (tType "Int" []) hInt
          , body = binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
          }
        , { name = "idf"
          , args = [ pVar "x" ]
          , tipe = hInt
          , body = varExpr "x"
          }
        , { name = "useIt"
          , args = [ pVar "f" ]
          , tipe = tLambda hInt (tType "Int" [])
          , body = callExpr (varExpr "f") [ intExpr 1 ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                callExpr (varExpr "useIt")
                    [ ifExpr (boolExpr True) (callExpr (varExpr "addTo") [ intExpr 7 ]) (varExpr "idf") ]
          }
        ]


{-| A module in which the only function value passed to `useIt` is the
partial application `addTo 7`.
-}
loneModule : Src.Module
loneModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "addTo"
          , args = [ pVar "a", pVar "b" ]
          , tipe = tLambda (tType "Int" []) hInt
          , body = binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
          }
        , { name = "useIt"
          , args = [ pVar "f" ]
          , tipe = tLambda hInt (tType "Int" [])
          , body = callExpr (varExpr "f") [ intExpr 1 ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body = callExpr (varExpr "useIt") [ callExpr (varExpr "addTo") [ intExpr 7 ] ]
          }
        ]


{-| A module in which the partial application `addTo 7` is the only function
value passed to `applyTwice`, which calls it twice.
-}
papDevirtModule : Src.Module
papDevirtModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "addTo"
          , args = [ pVar "a", pVar "b" ]
          , tipe = tLambda (tType "Int" []) hInt
          , body = binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
          }
        , { name = "applyTwice"
          , args = [ pVar "f", pVar "n" ]
          , tipe = tLambda hInt (tLambda (tType "Int" []) (tType "Int" []))
          , body = callExpr (varExpr "f") [ callExpr (varExpr "f") [ varExpr "n" ] ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body = callExpr (varExpr "applyTwice") [ callExpr (varExpr "addTo") [ intExpr 7 ], intExpr 1 ]
          }
        ]



-- ====== READERS ======


{-| Returns the demand type of every registry entry whose global is named
`target`, in any module.
-}
demandsOf : String -> Mono.MonoGraph -> List Mono.MonoType
demandsOf target (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ name, monoType ) ->
                    if name == target then
                        monoType :: acc

                    else
                        acc

                _ ->
                    acc
        )
        []
        g.registry.reverseMapping


{-| Returns every lambda-set annotation in the demand types of the globals
named `target`, except the annotation on each type's outermost arrow.

The solver stamps the own member of a global defined in the program, such as
`useIt`, on that arrow wherever the annotation is not already an `LSet`
(`Compiler.Monomorphize.Solver.Translate.stampSelfSpine`), and the resulting singleton
is correct, so reading it would fail test 1 for a correct graph. The
parameter the tests are about is below it. Skipping the outermost arrow alone
suffices for a one-parameter global such as `useIt`; the deeper spine arrows
of a global with more parameters are stamped too and are not skipped.

-}
allAnnos : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
allAnnos target graph =
    List.concatMap belowHead (demandsOf target graph)


{-| Returns every annotation in `t` except the one on its outermost arrow:
those of its parameters and its result. A type that is not a function has no
outermost arrow, and all its annotations are returned.
-}
belowHead : Mono.MonoType -> List Mono.LambdaSetAnno
belowHead t =
    case t of
        Mono.MFunction _ _ args ret ->
            List.concatMap annosOf args ++ annosOf ret

        _ ->
            annosOf t


{-| Returns every lambda-set annotation in `t`, looking inside functions,
lists, tuples, records and custom type arguments.
-}
annosOf : Mono.MonoType -> List Mono.LambdaSetAnno
annosOf t =
    case t of
        Mono.MFunction _ anno args ret ->
            anno :: (List.concatMap annosOf args ++ annosOf ret)

        Mono.MList _ el ->
            annosOf el

        Mono.MTuple _ els ->
            List.concatMap annosOf (Mono.tupleToList els)

        Mono.MRecord _ fields ->
            Dict.foldl (\_ ft acc -> acc ++ annosOf ft) [] fields

        Mono.MCustom _ _ _ args ->
            List.concatMap annosOf args

        _ ->
            []


{-| Returns the annotation on the head arrow of the first parameter of every
demand type of the globals named `target`, when that parameter is a function.
-}
paramHeadAnnos : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
paramHeadAnnos target graph =
    List.filterMap
        (\t ->
            case t of
                Mono.MFunction _ _ ((Mono.MFunction _ anno _ _) :: _) _ ->
                    Just anno

                _ ->
                    Nothing
        )
        (demandsOf target graph)


{-| Returns whether `anno` is an `LSet` whose one member the graph's
`lssMemberOrigins` records as a partial application of a global named `name`
with `supplied` arguments.
-}
isPapSingleton : String -> Int -> Mono.MonoGraph -> Mono.LambdaSetAnno -> Bool
isPapSingleton name supplied graph anno =
    case ( anno, originsOf graph anno ) of
        ( Mono.LSet [ _ ], [ Just (Mono.OriginPap _ n k) ] ) ->
            n == name && k == supplied

        _ ->
            False


{-| Returns the recorded origin of each member of an `LSet` or `LPartial`, for
a reader or a failure message.
-}
originsOf : Mono.MonoGraph -> Mono.LambdaSetAnno -> List (Maybe Mono.MemberOrigin)
originsOf (Mono.MonoGraph g) anno =
    case anno of
        Mono.LSet ms ->
            List.map (\m -> Dict.get m g.lssMemberOrigins) ms

        Mono.LPartial ms ->
            List.map (\m -> Dict.get m g.lssMemberOrigins) ms

        _ ->
            []


{-| Returns `False` when `anno` is an `LSet` of fewer than two members, a
complete set naming one function or none, and `True` for every other
annotation: `LTop`, `LVar`, `LPartial` and an `LSet` of two or more members.
-}
neverFalselyComplete : Mono.LambdaSetAnno -> Bool
neverFalselyComplete anno =
    case anno of
        Mono.LTop _ ->
            True

        Mono.LVar _ ->
            True

        Mono.LPartial _ ->
            True

        Mono.LSet ms ->
            List.length ms >= 2


{-| Renders `annos` for a failure message, as a bracketed, comma-separated list
of `describeAnno` renderings.
-}
describeAnnos : List Mono.LambdaSetAnno -> String
describeAnnos annos =
    "[" ++ String.join ", " (List.map describeAnno annos) ++ "]"


{-| Renders one annotation for a failure message: its constructor name, with an
`LVar`'s number, an `LSet`'s member count, or an `LPartial`'s member count
followed by its member ids.
-}
describeAnno : Mono.LambdaSetAnno -> String
describeAnno anno =
    case anno of
        Mono.LTop _ ->
            "LTop"

        Mono.LVar n ->
            "LVar " ++ String.fromInt n

        Mono.LSet ms ->
            "LSet " ++ String.fromInt (List.length ms)

        Mono.LPartial ms ->
            "LPartial " ++ String.fromInt (List.length ms) ++ String.concat (List.map (\m -> " " ++ String.fromInt m) ms)
