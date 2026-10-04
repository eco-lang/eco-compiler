module TestLogic.Monomorphize.LssRegIdentityTest exposing (suite)

{-| Checks the solver engine's registration self-identity stamp. Without these
tests, a change that kept the stamp from reaching a specialization's stored
type, or that let it make a function parameter look as if only one function
could reach it when two can, would go unnoticed.

Under lambda-set specialization (LSS), every arrow of a `MonoType` carries a
`Mono.LambdaSetAnno` naming the function values, its _members_, that can flow
through it: `LSet` (exactly these), `LPartial` (at least these), `LVar` (a
set variable) or `LTop` (unknown, written ⊤). A set with one member is a
_singleton_. The _spine_ of a function type is its chain of arrows: depth 0 is
the arrow taking the first argument, depth 1 the arrow of the function left
after one argument, and so on.

The stamp rests on one fact. A specialization is registered under its global
as well as its type, so a value at depth `d` of the stored type is that global
applied to `d` arguments, whatever the rest of the program does.
`Compiler.MonoSolver.Translate.stampSelfSpine` therefore writes a singleton
`LSet` at each depth of the stored type's spine, up to the global's declared
arity and at least the head arrow, wherever the annotation is not already an
`LSet`, which it leaves as it is. Some globals, such as raw kernels, effect
managers and ports, have no member of their own, and their stored types are
left unstamped.

`runWith` runs a fixture module through the solver engine with LSS on, and
the readers below collect annotations from the output graph's registry: the
stored type of every specialization of a global with a given name. In these
tests a _set_ is any `LSet`, of any size, including an empty one.

The tests establish:

  - Test 1 (`plainModule`): every stored function type of `double`
    (`Int -> Int`) has a set at its head, whatever its size. It fails if
    `double` has no stored function type.
  - Test 2a (`plainModule`): every stored function type of `plus2`
    (`Int -> Int -> Int`, two parameters) has a set at depth 0, and also at
    depth 1 when the stored type has a second arrow. It fails if `plus2` has
    no stored function type.
  - Test 3 (`consModule`, whose `testValue` is `double :: []`): every head
    annotation of a stored function type of a global named `cons` is `LTop`
    or a set; `LVar` and `LPartial` fail. `List.cons` is a kernel alias in the
    test pipeline's graph. The test passes when no such specialization is
    registered.
  - Test 4 (`joinModule`): `useIt` takes an `Int -> Int` and is called with
    `if True then addTo 7 else idf`, so two different function values can
    reach its parameter. Every function-typed parameter of `useIt`'s stored
    types must be `LTop`, `LVar`, `LPartial`, or a set of at least two
    members; a singleton or an empty set fails. It fails if no such
    parameter is found.

Among what is not tested:

  - That the stamp stops at declared arity. `retModule` has a global, `ret1`,
    whose type has more arrows than it has parameters, but no test runs it.
  - That the stamp leaves an existing `LSet` unchanged.
  - Which members the stamp writes, or that a stamped arrow is a singleton.
  - The substitution engine, which `TestPipeline.runSubstMonoWithLimits` runs
    with no LSS configuration at all.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , boolExpr
        , callExpr
        , ifExpr
        , intExpr
        , lambdaExpr
        , listExpr
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


{-| The registration self-identity tests, as the module docstring lists them.
-}
suite : Test
suite =
    Test.describe "tautological self-identity at spec registration"
        [ Test.test "1. a plain def's stored head anno is a COVERED SET" <|
            \() ->
                case runWith plainModule of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        case headAnnos "double" g of
                            [] ->
                                Expect.fail "no spec registered for `double` — fixture broken"

                            onHeads ->
                                if List.all isSet onHeads then
                                    Expect.pass

                                else
                                    Expect.fail ("head expected covered sets, got " ++ describe onHeads)
        , Test.test "2a. ARITY: both spine depths of a 2-ary def are stamped" <|
            \() ->
                case runWith plainModule of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        let
                            spines =
                                List.filterMap spineAnnos (demandsOf "plus2" g)
                        in
                        if List.isEmpty spines then
                            Expect.fail "no spec registered for `plus2` — fixture broken"

                        else if List.all (\( h, r ) -> isSet h && maybeSet r) spines then
                            Expect.pass

                        else
                            Expect.fail
                                ("expected covered sets at depths 0 and 1: "
                                    ++ String.join "; " (List.map (\( h, r ) -> describeAnno h ++ " / " ++ describeMaybe r) spines)
                                )
        , Test.test "3. KERNEL BOUNDARY: a kernel-alias spec's head stays ⊤ (documented residue)" <|
            \() ->
                case runWith consModule of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        case headAnnos "cons" g of
                            [] ->
                                -- Unlike the other tests, finding nothing passes.
                                Expect.pass

                            heads ->
                                if List.all (\a -> isTop a || isSet a) heads then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("kernel-alias head must be ⊤ or a set, got: "
                                            ++ describe heads
                                        )
        , Test.test "4. CO-GATE: a one-sided join is still never a false singleton" <|
            \() ->
                case runWith joinModule of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        case paramAnnos "useIt" g of
                            [] ->
                                Expect.fail "no demand recorded for `useIt` — fixture broken"

                            annos ->
                                if List.all neverFalselyComplete annos then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("a one-sided join published a singleton under regIdentity: "
                                            ++ describe annos
                                        )
        ]



-- ====== FIXTURES ======


{-| The source type `Int -> Int`.
-}
hInt : Src.Type
hInt =
    tLambda (tType "Int" []) (tType "Int" [])


{-| A module with two annotated functions that `testValue` calls with all
their arguments: `double x = x + x`, of type `Int -> Int`, and
`plus2 a b = a + b`, of type `Int -> Int -> Int`.
-}
plainModule : Src.Module
plainModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "double"
          , args = [ pVar "x" ]
          , tipe = hInt
          , body = binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "x")
          }
        , { name = "plus2"
          , args = [ pVar "a", pVar "b" ]
          , tipe = tLambda (tType "Int" []) hInt
          , body = binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body = binopsExpr [ ( callExpr (varExpr "double") [ intExpr 3 ], "+" ) ] (callExpr (varExpr "plus2") [ intExpr 1, intExpr 2 ])
          }
        ]


{-| A module whose `ret1 : Int -> Int -> Int` takes one parameter and returns
`double`, so its type has one more arrow than its parameters. `testValue`
applies `ret1 0` to `7`. No test uses this module.
-}
retModule : Src.Module
retModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "double"
          , args = [ pVar "x" ]
          , tipe = hInt
          , body = binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "x")
          }
        , { name = "ret1"
          , args = [ pVar "n" ]
          , tipe = tLambda (tType "Int" []) hInt
          , body = varExpr "double"
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body = callExpr (callExpr (varExpr "ret1") [ intExpr 0 ]) [ intExpr 7 ]
          }
        ]


{-| A module whose `testValue`, of type `List (Int -> Int)`, is `double :: []`,
so the function `double` is passed to `::`, which the test interfaces
define as `List.cons`.
-}
consModule : Src.Module
consModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "double"
          , args = [ pVar "x" ]
          , tipe = hInt
          , body = binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "x")
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "List" [ hInt ]
          , body = binopsExpr [ ( varExpr "double", "::" ) ] (listExpr [])
          }
        ]


{-| A module in which `useIt`, of type `(Int -> Int) -> Int`, applies its
parameter to `1`, and `testValue` calls it with
`if True then addTo 7 else idf`. The two branches are different function
values: a partial application of the two-parameter `addTo`, and the
identity function `idf`.
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



-- ====== HARNESS ======


{-| Runs `srcModule` through the test pipeline to the solver engine's
monomorphized graph, with the default specialization limits and the default
LSS configuration, in which LSS is on. An `Err` carries the failing stage's
message.
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


{-| Returns the stored type of every registered specialization of a global
named `target`, from any module.
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


{-| Returns the head annotation of each stored function type of a global named
`target`. Stored types that are not functions are skipped.
-}
headAnnos : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
headAnnos target graph =
    List.filterMap
        (\t ->
            case t of
                Mono.MFunction _ anno _ _ ->
                    Just anno

                _ ->
                    Nothing
        )
        (demandsOf target graph)


{-| Returns the annotations at depth 0 and depth 1 of a function type, the
second being `Nothing` when the type has no arrow at depth 1. A type that is
not a function gives `Nothing`.
-}
spineAnnos : Mono.MonoType -> Maybe ( Mono.LambdaSetAnno, Maybe Mono.LambdaSetAnno )
spineAnnos t =
    case t of
        Mono.MFunction _ anno _ ret ->
            case ret of
                Mono.MFunction _ rAnno _ _ ->
                    Just ( anno, Just rAnno )

                _ ->
                    Just ( anno, Nothing )

        _ ->
            Nothing


{-| Returns the head annotation of each function-typed parameter taken by the
outermost arrow of each stored function type of a global named `target`.
-}
paramAnnos : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
paramAnnos target graph =
    List.concatMap
        (\t ->
            case t of
                Mono.MFunction _ _ args _ ->
                    List.filterMap
                        (\a ->
                            case a of
                                Mono.MFunction _ anno _ _ ->
                                    Just anno

                                _ ->
                                    Nothing
                        )
                        args

                _ ->
                    []
        )
        (demandsOf target graph)


{-| Tells whether an annotation is `LTop`.
-}
isTop : Mono.LambdaSetAnno -> Bool
isTop a =
    Mono.isTopAnno a


{-| Tells whether an annotation is an `LSet` with exactly one member. No test
uses it.
-}
isSingleton : Mono.LambdaSetAnno -> Bool
isSingleton a =
    case a of
        Mono.LSet [ _ ] ->
            True

        _ ->
            False


{-| Tells whether an optional annotation is an `LSet`. `Nothing`, which
`spineAnnos` gives for a type with no arrow at depth 1, counts as passing.
-}
maybeSet : Maybe Mono.LambdaSetAnno -> Bool
maybeSet m =
    case m of
        Just a ->
            isSet a

        Nothing ->
            True


{-| Tells whether an annotation is an `LSet`, of any size, including empty.
-}
isSet : Mono.LambdaSetAnno -> Bool
isSet a =
    case a of
        Mono.LSet _ ->
            True

        _ ->
            False


{-| Tells whether an annotation leaves room for more than one function: `LTop`,
`LVar`, `LPartial`, or an `LSet` with at least two members. A singleton or
an empty `LSet` gives `False`.
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


{-| Renders a list of annotations for a failure message, each as `describeAnno`
renders it.
-}
describe : List Mono.LambdaSetAnno -> String
describe annos =
    "[" ++ String.join ", " (List.map describeAnno annos) ++ "]"


{-| Renders an optional annotation for a failure message, as `describeAnno`
does, or says that there is no arrow at depth 1.
-}
describeMaybe : Maybe Mono.LambdaSetAnno -> String
describeMaybe m =
    case m of
        Just a ->
            describeAnno a

        Nothing ->
            "(no /r arrow)"


{-| Renders an annotation for a failure message: its constructor and, for
`LVar`, its number, or for `LSet` and `LPartial`, how many members it has.
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
            "LPartial " ++ String.fromInt (List.length ms)
