module TestLogic.Monomorphize.LssInjTotalTest exposing (suite)

{-| Lambda-set inference should give a function value a member id at each
arrow it can be called through. An arrow it leaves unwritten reads back as
`LVar`, meaning not yet determined (see `Compiler.MonoSolver.Store`), and a
singleton `LSet`, a set with exactly one member, names a single function value
for the arrow. These tests check two kinds of position, one holding a later
stage of a partial application and one holding an accessor passed as an
argument. Tests 1 and 3 assert that every annotation found at their position
is a singleton.

A lambda-set annotation (`Mono.LambdaSetAnno`, described in
`Compiler.AST.Monomorphized`) names the function values that can flow through
an arrow, as integer member ids. A deep partial application is one that still
needs more than one argument, such as `add3 10`: calling it with one argument
gives another partial application, which has an arrow of its own.

The tests read annotations from the demand types that the specialization
registry records for a definition, one per row whose global has the given
name. In a demand type, `/a0` is the head arrow of the definition's first
parameter, when that parameter is a function, and `/a0/r` is the arrow of that
parameter's result, when the result is itself a function. A parameter whose
type takes two arguments at one arrow has no `/a0/r`.

The fixture is one module, `fixture`, run through the solver engine with
lambda-set specialization on. Its `testValue` adds the results of four calls:

  - `useIt (add3 10) 1`, where `useIt g n = g n n` takes an
    `Int -> Int -> Int` and `add3` adds three `Int`s;
  - `useOne ((add3 10) 1) 2`, where `useOne g n = g n` takes an `Int -> Int`;
  - `useMk mk 3`, where `mk x = add2 x`;
  - `useF .name mkRec`, where `useF f r = f r` and `mkRec` is the record
    `{ name = 5 }`.

The tests:

  - Test 1 asserts that at least one `useIt` row has an `/a0/r`, and that every
    `/a0/r` found is a singleton. That arrow is the second stage of `add3 10`.
  - Test 2 asserts that the first singleton id found at `useIt`'s `/a0/r`
    equals the first singleton id found at `useOne`'s `/a0`, and fails if
    either side has none. Both positions hold `add3` with two arguments
    supplied, reached once as the second stage of `add3 10` and once built
    directly as `(add3 10) 1`, so the assertion is that the two routes give
    that value one member id.
  - Test 3 asserts that at least one `useF` row has an `/a0`, and that every
    `/a0` found is a singleton. The argument there is the accessor `.name`.

Among what is not tested: which member the singletons in tests 1 and 3 hold,
although test 3's name says the accessor's; the `mk` and `useMk` part of the
fixture, which no test reads; and any position of `useIt` other than `/a0/r`.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( accessorExpr
        , binopsExpr
        , callExpr
        , intExpr
        , makeModuleWithTypedDefs
        , pVar
        , tLambda
        , tRecord
        , tType
        , varExpr
        )
import Compiler.Eco.Config as Config
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The three tests on `fixture`, described in the module docstring.
-}
suite : Test
suite =
    Test.describe "L2 deep-PAP + L3 accessor arm"
        [ Test.test "1. L2: deep-PAP /a0/r is a SINGLETON" <|
            \() ->
                case runWith fixture of
                    Ok onG ->
                        case a0rAnnos "useIt" onG of
                            [] ->
                                Expect.fail "no /a0/r for useIt — fixture broken"

                            onA ->
                                if List.all isSingleton onA then
                                    Expect.pass

                                else
                                    Expect.fail ("/a0/r expected SINGLETON, got " ++ describe onA)

                    Err e ->
                        Expect.fail e
        , Test.test "2. L2 PRODUCER CONVERGENCE: deep id == deeper-producer id" <|
            \() ->
                case runWith fixture of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        case ( singletonIds (a0rAnnos "useIt" g), singletonIds (a0Annos "useOne" g) ) of
                            ( deepId :: _, prodId :: _ ) ->
                                if deepId == prodId then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("deep id "
                                            ++ String.fromInt deepId
                                            ++ " /= producer id "
                                            ++ String.fromInt prodId
                                        )

                            ( ds, ps ) ->
                                Expect.fail
                                    ("expected singletons both ends, got deep="
                                        ++ String.fromInt (List.length ds)
                                        ++ " prod="
                                        ++ String.fromInt (List.length ps)
                                    )
        , Test.test "3. L3: an accessor argument head carries the a|name singleton" <|
            \() ->
                case runWith fixture of
                    Ok onG ->
                        case a0Annos "useF" onG of
                            [] ->
                                Expect.fail "no /a0 for useF — fixture broken"

                            onA ->
                                if List.all isSingleton onA then
                                    Expect.pass

                                else
                                    Expect.fail ("accessor /a0 expected SINGLETON, got " ++ describe onA)

                    Err e ->
                        Expect.fail e
        ]



-- ====== FIXTURE ======


{-| The source type `Int`.
-}
hInt : Src.Type
hInt =
    tType "Int" []


{-| The source type `Int -> Int -> Int`.
-}
int2 : Src.Type
int2 =
    tLambda hInt (tLambda hInt hInt)


{-| The source type `Int -> Int -> Int -> Int`.
-}
int3 : Src.Type
int3 =
    tLambda hInt int2


{-| The source record type `{ name : Int }`.
-}
rec : Src.Type
rec =
    tRecord [ ( "name", hInt ) ]


{-| The module `Test` that every test compiles, with the definitions the
module docstring describes, a helper `mkRecHelp` that builds `mkRec`'s record,
and the `testValue` that makes them reachable.
-}
fixture : Src.Module
fixture =
    makeModuleWithTypedDefs "Test"
        [ { name = "add3"
          , args = [ pVar "a", pVar "b", pVar "c" ]
          , tipe = int3
          , body = binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c")
          }
        , { name = "add2"
          , args = [ pVar "a", pVar "b" ]
          , tipe = int2
          , body = binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
          }
        , { name = "useIt"
          , args = [ pVar "g", pVar "n" ]
          , tipe = tLambda int2 (tLambda hInt hInt)
          , body = callExpr (varExpr "g") [ varExpr "n", varExpr "n" ]
          }
        , { name = "useOne"
          , args = [ pVar "g", pVar "n" ]
          , tipe = tLambda (tLambda hInt hInt) (tLambda hInt hInt)
          , body = callExpr (varExpr "g") [ varExpr "n" ]
          }
        , { name = "useF"
          , args = [ pVar "f", pVar "r" ]
          , tipe = tLambda (tLambda rec hInt) (tLambda rec hInt)
          , body = callExpr (varExpr "f") [ varExpr "r" ]
          }
        , { name = "mk"
          , args = [ pVar "x" ]
          , tipe = int2
          , body = callExpr (varExpr "add2") [ varExpr "x" ]
          }
        , { name = "useMk"
          , args = [ pVar "f", pVar "n" ]
          , tipe = tLambda int2 (tLambda hInt hInt)
          , body = callExpr (varExpr "f") [ varExpr "n", varExpr "n" ]
          }
        , { name = "testValue"
          , args = []
          , tipe = hInt
          , body =
                binopsExpr
                    [ ( callExpr (varExpr "useIt") [ callExpr (varExpr "add3") [ intExpr 10 ], intExpr 1 ], "+" )
                    , ( callExpr (varExpr "useOne") [ callExpr (callExpr (varExpr "add3") [ intExpr 10 ]) [ intExpr 1 ], intExpr 2 ], "+" )
                    , ( callExpr (varExpr "useMk") [ varExpr "mk", intExpr 3 ], "+" )
                    ]
                    (callExpr (varExpr "useF") [ accessorExpr "name", callExpr (varExpr "mkRec") [] ])
          }
        , { name = "mkRec"
          , args = []
          , tipe = rec
          , body = callExpr (varExpr "mkRecHelp") [ intExpr 5 ]
          }
        , { name = "mkRecHelp"
          , args = [ pVar "n" ]
          , tipe = tLambda hInt rec
          , body = Compiler.AST.SourceBuilder.recordExpr [ ( "name", varExpr "n" ) ]
          }
        ]



-- ====== HARNESS ======


{-| Compiles `srcModule` through monomorphization on the solver engine, with
the default specialization limits and the default lambda-set configuration
with `enabled` set, and returns the graph or the pipeline's error message.
`enabled` is already `True` in `Config.defaultLss`.
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


{-| Returns the demand type of every specialization registry row whose global
is a definition named `target`, in any module. Accessor rows and removed rows
are skipped.
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


{-| Returns the `/a0` annotation, the head arrow of the first parameter, from
each demand type of `target` whose first parameter is a function. Other rows
contribute nothing.
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


{-| Returns the `/a0/r` annotation, the arrow of the first parameter's result,
from each demand type of `target` whose first parameter is a function
returning a function. Other rows contribute nothing.
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


{-| Returns the member id of each annotation that is an `LSet` with exactly one
member, dropping the rest.
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


{-| Returns whether an annotation is an `LSet` with exactly one member. An
`LPartial` with one member is not a singleton.
-}
isSingleton : Mono.LambdaSetAnno -> Bool
isSingleton a =
    case a of
        Mono.LSet [ _ ] ->
            True

        _ ->
            False


{-| Renders a list of annotations for a failure message, each as its
constructor name with, for `LVar`, its number and, for `LSet` and `LPartial`,
its member count.
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
