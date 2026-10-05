module TestLogic.Monomorphize.LssRefPapSpineTest exposing (suite)

{-| Checks that a global passed by reference and the same global partially
applied are given the same lambda-set member where both stand for the global
applied to one argument, when the solver monomorphizer runs with lambda-set
specialization on. If the two gave different ids, one partial application would
be named by two members, and a set that receives it both ways would hold two
members where one is meant.

A lambda set is the set of functions an arrow in a monomorphic type may hold at
run time, written on each `Mono.MFunction` as a `Mono.LambdaSetAnno`. A
singleton set, `LSet [ m ]`, names exactly one member `m`, an interned integer
id. Positions in a parameter's type are written as paths: `/a0` is the arrow of
a function's first parameter, and `/a0/r` is the arrow of that parameter's
result type. The solver engine builds function types with one parameter per
arrow, so `/a0/r` is the value left after applying the argument once.

Passing a two-argument global `g` by reference writes `g`'s own member on the
head arrow of the reference's type, which is the argument passed at `/a0`. The
reference-spine walk (`injectPapSuccessors` in `Compiler.MonoSolver.LssInfer`)
also writes, at each depth `d` from 1 up to one less than `g`'s declared arity,
the number of parameters its definition names, the member keyed `p|g|d`, which
names `g` applied to `d` arguments. The partial application `g 1` is given the member
keyed `p|g|1` by a different path, which writes it on the head arrow of the
value it produces. Both paths take the id from
`Compiler.MonoSolver.Engine.papMemberIdFor`, which interns the key, so the same
key gives the same id.

The fixture defines `plus2 : Int -> Int -> Int` and three callers that take a
two-argument function, or a one-argument one, as their first parameter.
`testValue` calls `useIt plus2 1`, `useIt2 (plus2 1) 2` and `useIt3 mk 3`, which
makes all of them reachable from the `main` that `TestLogic.TestPipeline` adds.
`mk` has an `Int -> Int -> Int` annotation but one parameter, so its declared
arity is less than its type's arrow count, and the walk writes no `p|mk|d`
member for it. The readers find a global's specializations by unqualified name
in the graph's registry, and a member's origin in its `lssMemberOrigins`.

The tests establish:

  - Test 1: at least one specialization of `useIt` has a `/a0/r` position, and
    at every one that has, the annotation is a singleton `LSet` whose member
    is recorded as `plus2` applied to one argument (`p|plus2|1`).
  - Test 2: every singleton found at `useIt`'s `/a0/r` and at `useIt2`'s `/a0`
    names one and the same member, and both positions hold at least one
    singleton.
  - Test 3: `useIt3`'s `/a0/r` is, in every specialization, the singleton
    `p|plus2|1` (what `mk x` returns), and no member is recorded as a partial
    application of `mk`: the walk stops at `mk`'s declared arity.

Among what is not tested: what `/a0` of `useIt` holds, and the graph after
global optimization.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , intExpr
        , makeModuleWithTypedDefs
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import Compiler.Eco.Config as Config
import Dict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The reference-spine identity tests, run on the fixture.
-}
suite : Test
suite =
    Test.describe "PAP successors on reference spines"
        [ Test.test "1. /a0/r of a referenced multi-arg global is a SINGLETON" <|
            \() ->
                case runWith fixture of
                    Ok onG ->
                        case a0rAnnos "useIt" onG of
                            [] ->
                                Expect.fail "no /a0/r position for `useIt` — fixture broken"

                            onAnnos ->
                                if List.all (isPapSingleton "plus2" 1 onG) onAnnos then
                                    Expect.pass

                                else
                                    Expect.fail ("/a0/r expected the SINGLETON p|plus2|1 member, got " ++ describe onAnnos)

                    Err e ->
                        Expect.fail e
        , Test.test "2. PRODUCER CONVERGENCE: reference-spine id == partial-application id" <|
            \() ->
                case runWith fixture of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        case ( singletonIds (a0rAnnos "useIt" g), singletonIds (a0Annos "useIt2" g) ) of
                            ( spineId :: spineRest, prodId :: prodRest ) ->
                                if List.all ((==) spineId) (spineRest ++ prodId :: prodRest) then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("spine ids "
                                            ++ String.join ", " (List.map String.fromInt (spineId :: spineRest))
                                            ++ " /= producer ids "
                                            ++ String.join ", " (List.map String.fromInt (prodId :: prodRest))
                                            ++ " — the two p| mints diverged"
                                        )

                            ( sp, pr ) ->
                                Expect.fail
                                    ("expected singletons at both ends, got spine="
                                        ++ String.fromInt (List.length sp)
                                        ++ " producer="
                                        ++ String.fromInt (List.length pr)
                                    )
        , Test.test "3. DECLARED-ARITY BOUND: a one-parameter global under two arrows mints no p| successor of its own" <|
            \() ->
                case runWith fixture of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        case a0rAnnos "useIt3" g of
                            [] ->
                                Expect.fail "no /a0/r position for `useIt3` — fixture broken"

                            annos ->
                                Expect.all
                                    [ \_ ->
                                        -- `mk x` is the partial application `plus2 x`.
                                        if List.all (isPapSingleton "plus2" 1 g) annos then
                                            Expect.pass

                                        else
                                            Expect.fail ("useIt3's /a0/r expected the SINGLETON p|plus2|1 member, got " ++ describe annos)
                                    , \_ -> Expect.equal [] (papMembersOf "mk" g)
                                    ]
                                    ()
        ]



-- ====== FIXTURE ======


{-| The source type `Int`.
-}
hInt : Src.Type
hInt =
    tType "Int" []


{-| The source type `Int -> Int -> Int`, of a two-argument integer function.
-}
int2 : Src.Type
int2 =
    tLambda hInt (tLambda hInt hInt)


{-| The test program, a module named `Test` whose definitions are described in
the module docstring.
-}
fixture : Src.Module
fixture =
    makeModuleWithTypedDefs "Test"
        [ { name = "plus2"
          , args = [ pVar "a", pVar "b" ]
          , tipe = int2
          , body = binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
          }
        , { name = "useIt"
          , args = [ pVar "f", pVar "n" ]
          , tipe = tLambda int2 (tLambda hInt hInt)
          , body = callExpr (varExpr "f") [ varExpr "n", varExpr "n" ]
          }
        , { name = "useIt2"
          , args = [ pVar "g", pVar "n" ]
          , tipe = tLambda (tLambda hInt hInt) (tLambda hInt hInt)
          , body = callExpr (varExpr "g") [ varExpr "n" ]
          }
        , { name = "mk"
          , args = [ pVar "x" ]

          -- One parameter under a two-arrow type: the second arrow is the
          -- type of the body, the partial application `plus2 x`.
          , tipe = int2
          , body = callExpr (varExpr "plus2") [ varExpr "x" ]
          }
        , { name = "useIt3"
          , args = [ pVar "f", pVar "n" ]
          , tipe = tLambda int2 (tLambda hInt hInt)
          , body = callExpr (varExpr "f") [ varExpr "n", varExpr "n" ]
          }
        , { name = "testValue"
          , args = []
          , tipe = hInt
          , body =
                binopsExpr
                    [ ( callExpr (varExpr "useIt") [ varExpr "plus2", intExpr 1 ], "+" )
                    , ( callExpr (varExpr "useIt2") [ callExpr (varExpr "plus2") [ intExpr 1 ], intExpr 2 ], "+" )
                    ]
                    (callExpr (varExpr "useIt3") [ varExpr "mk", intExpr 3 ])
          }
        ]



-- ====== HARNESS ======


{-| Monomorphizes `srcModule` with the solver engine, the default
specialization limits, and the default lambda-set configuration with `enabled`
set, returning the graph before global optimization.
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


{-| Returns the type of every specialization in the graph's registry whose
global's unqualified name is `target`, from any module.
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


{-| Returns the `/a0` annotation, on the first parameter's own arrow, of each
specialization of `target` whose first parameter is a function.
-}
a0Annos : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
a0Annos target graph =
    List.filterMap
        (\t ->
            case t of
                Mono.MFunction _ _ ((Mono.MFunction _ anno _ _) :: _) _ ->
                    Just anno

                _ ->
                    Nothing
        )
        (demandsOf target graph)


{-| Returns the `/a0/r` annotation, on the arrow of the first parameter's
result, of each specialization of `target` where that result is a function.
-}
a0rAnnos : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
a0rAnnos target graph =
    List.filterMap
        (\t ->
            case t of
                Mono.MFunction _ _ ((Mono.MFunction _ _ _ (Mono.MFunction _ rAnno _ _)) :: _) _ ->
                    Just rAnno

                _ ->
                    Nothing
        )
        (demandsOf target graph)


{-| Returns the member of each annotation that is a one-member `LSet`, dropping
every other annotation.
-}
singletonIds : List Mono.LambdaSetAnno -> List Int
singletonIds =
    List.filterMap
        (\a ->
            case a of
                Mono.LSet [ m ] ->
                    Just m

                _ ->
                    Nothing
        )


{-| Tells whether an annotation is an `LSet` whose one member the graph's
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


{-| Returns every member the graph's `lssMemberOrigins` records as a partial
application of a global named `name`, with any number of arguments supplied.
-}
papMembersOf : String -> Mono.MonoGraph -> List Int
papMembersOf name (Mono.MonoGraph g) =
    Dict.foldl
        (\m origin acc ->
            case origin of
                Mono.OriginPap (Mono.Global _ n) _ ->
                    if n == name then
                        m :: acc

                    else
                        acc

                _ ->
                    acc
        )
        []
        g.lssMemberOrigins


{-| Renders annotations for a failure message, each as its constructor name,
followed by the variable number for an `LVar` and the member count for an
`LSet` or `LPartial`.
-}
describe : List Mono.LambdaSetAnno -> String
describe annos =
    "["
        ++ String.join ", "
            (List.map
                (\a ->
                    case a of
                        Mono.LTop _ ->
                            "LTop"

                        Mono.LVar n ->
                            "LVar " ++ String.fromInt n

                        Mono.LSet ms ->
                            "LSet " ++ String.fromInt (List.length ms)

                        Mono.LPartial ms ->
                            "LPartial " ++ String.fromInt (List.length ms)
                )
                annos
            )
        ++ "]"
