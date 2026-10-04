module TestLogic.Monomorphize.LssRootFoldTest exposing (suite)

{-| Checks the root-member fold of the solver engine's lambda-set
specialization. Without the fold, a top-level function could reach one arrow
under two member ids, and an annotation that should name one function would
name two.

Under lambda-set specialization each function arrow of a monomorphized type
carries an annotation, a `Compiler.AST.Monomorphized.LambdaSetAnno`, saying
which function values can arrive there. An `LSet` lists them as _member ids_,
integers that each name one function value, and a one-member `LSet`, a
_singleton_, is what lets a call go straight to a known function. `LTop` means
unknown, `LVar` is an unresolved variable, and `LPartial` means "at least these
members". The _head_ of a specialization's type is its outermost arrow, and
_depth 1_ is the arrow of the function that is left after one argument.

A top-level function such as `double` gets a member id in two ways. Its body
is a lambda, which is given a member id when it is translated, and a reference
to `double` used as a value is given the global's own standalone member id.
Under the _root-member fold_ the lambda at the root of a top-level definition
takes the global's standalone id instead of one of its own, so both ways give
the same id. `Compiler.MonoSolver.Engine` (`lambdaInstanceMemberId`) owns the
fold. Two of its limits matter here. A definition that is an alias of a kernel
is not folded (`Compiler.MonoSolver.Translate`), because references to such an
alias carry the kernel's own member id (`Compiler.MonoSolver.LssInfer`). And
the folded id is written on the definition's head only, with
partial-application members at the deeper arrows (`Compiler.MonoSolver.LssInfer`),
because the folded id names the whole function, not what is left of it after
an argument.

Each fixture is a module `Test` of annotated definitions over `Int`, built with
`makeModuleWithTypedDefs`. `TestLogic.TestPipeline` adds a `main` that uses
`testValue`, which reaches the other definitions. `runWith` monomorphizes a
fixture with the solver engine under the default lambda-set configuration, in
which the fold has no switch of its own, and the readers take the types of a
global's specializations, by name, from the graph's registry.

  - Test 1 (`refModule`, where `testValue` is `useIt double 3`): the first
    singleton among `double`'s head annotations and the first singleton among
    the annotations of `useIt`'s function-typed parameter are the same member
    id. It fails if either side has no singleton.
  - Test 3 (`consModule`, where `testValue` is `double :: []`): no head
    annotation of a specialization named `cons` is an `LSet` of more than two
    members. `LTop`, `LVar` and `LPartial` pass, and so does finding no `cons`
    specialization.
  - Test 4 (`plainModule`): no member id of an `LSet` at `plus2`'s head appears
    in an `LSet` at its depth 1. It fails if `plus2`'s head annotations hold no
    `LSet` member. It compares ids rather than set sizes, because sets of equal
    size do not show which member is at which depth.
  - Test 5 (`joinModule`, where `useIt` is given
    `if True then addTo 7 else idf`): every annotation on `useIt`'s
    function-typed parameter is `LTop`, `LVar`, `LPartial` or an `LSet` of at
    least two members, so the join of the partial application `addTo 7` with
    the global `idf` does not read as a singleton. It fails if there is no such
    annotation.

Among what is not tested: the subst engine and lambda-set specialization
switched off; let-bound functions; a definition specialized at more than one
type; arrows deeper than depth 1; and, in test 3, an `LVar` head, which the
check accepts.

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


{-| The four root-member fold tests, numbered 1, 3, 4 and 5.
-}
suite : Test
suite =
    Test.describe "root-member fold — one member id per (function, layout)"
        [ Test.test "1. CONVERGENCE: the stored head id IS the reference-flow id" <|
            \() ->
                case runWith refModule of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        case ( singletonIds (headAnnos "double" g), singletonIds (paramAnnos "useIt" g) ) of
                            ( headId :: _, paramId :: _ ) ->
                                if headId == paramId then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("stored head id "
                                            ++ String.fromInt headId
                                            ++ " /= reference-flow id "
                                            ++ String.fromInt paramId
                                            ++ " — the fold and the reference path diverged"
                                        )

                            ( hs, ps ) ->
                                Expect.fail
                                    ("expected singletons at both ends, got head="
                                        ++ String.fromInt (List.length hs)
                                        ++ " param="
                                        ++ String.fromInt (List.length ps)
                                    )
        , Test.test "3. KERNEL-ALIAS SKIP: no new split at a kernel-backed head" <|
            \() ->
                case runWith consModule of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        case headAnnos "cons" g of
                            [] ->
                                Expect.pass

                            heads ->
                                if List.all (\a -> Mono.isTopAnno a || sizeAtMost 2 a) heads then
                                    Expect.pass

                                else
                                    Expect.fail ("kernel-alias head grew a new identity: " ++ describe heads)
        , Test.test "4. DEEP SPINE: the folded head id is absent from depth 1" <|
            \() ->
                case runWith plainModule of
                    Ok g ->
                        let
                            heads =
                                List.concatMap annoMembers (headAnnos "plus2" g)

                            deep =
                                List.concatMap annoMembers (depth1Annos "plus2" g)

                            leaked =
                                List.filter (\m -> List.member m deep) heads
                        in
                        if List.isEmpty heads then
                            Expect.fail "no head member for `plus2` — fixture broken"

                        else if List.isEmpty leaked then
                            Expect.pass

                        else
                            Expect.fail
                                ("AR-1 violated: head member(s) "
                                    ++ String.join "," (List.map String.fromInt leaked)
                                    ++ " appear at depth 1 "
                                    ++ String.join "," (List.map String.fromInt deep)
                                )

                    Err e ->
                        Expect.fail e
        , Test.test "5. CO-GATE: the crash shape publishes no false singleton" <|
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
                                        ("a one-sided join published a singleton under rootFold: "
                                            ++ describe annos
                                        )
        ]



-- ====== FIXTURES ======


{-| The source type `Int -> Int`, the type of the fixtures' one-argument
functions and of the function that `useIt` takes.
-}
hInt : Src.Type
hInt =
    tLambda (tType "Int" []) (tType "Int" [])


{-| A fixture defining `double x = x + x` and `plus2 a b = a + b`, with a
`testValue` that calls each with all of its arguments.
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


{-| A fixture in which `testValue` is `useIt double 3`, so that `double` reaches
`useIt`'s parameter as a value, and `useIt f n` applies `f` to `n`.
-}
refModule : Src.Module
refModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "double"
          , args = [ pVar "x" ]
          , tipe = hInt
          , body = binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "x")
          }
        , { name = "useIt"
          , args = [ pVar "f", pVar "n" ]
          , tipe = tLambda hInt hInt
          , body = callExpr (varExpr "f") [ varExpr "n" ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body = callExpr (varExpr "useIt") [ varExpr "double", intExpr 3 ]
          }
        ]


{-| A fixture in which `testValue` is `double :: []`, a list holding the function
`double`. The `::` is `List.cons`, which the test pipeline gives a node that
is an alias of the kernel.
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


{-| A fixture in which `useIt f = f 1` is given `if True then addTo 7 else idf`:
a partial application of the two-argument `addTo` and the one-argument `idf`,
joined into one function-typed value.
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


{-| Monomorphizes `srcModule` with the solver engine under the default
lambda-set configuration and the default specialization limits, giving the
graph before global optimization, or the pipeline's error message. Setting
`enabled = True` restates the default.
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


{-| Returns the member ids of an `LSet`, or `[]` for any other annotation,
`LPartial` included.
-}
annoMembers : Mono.LambdaSetAnno -> List Int
annoMembers a =
    case a of
        Mono.LSet ms ->
            ms

        _ ->
            []



-- ====== READERS ======


{-| Returns the type of every specialization in the registry of `graph` whose
global is named `target`, whatever its module.
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


{-| Returns the head annotation of each function-typed specialization of
`target`.
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


{-| Returns the depth-1 annotation of each specialization of `target` whose head
arrow returns a function.
-}
depth1Annos : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
depth1Annos target graph =
    List.filterMap
        (\t ->
            case t of
                Mono.MFunction _ _ _ (Mono.MFunction _ rAnno _ _) ->
                    Just rAnno

                _ ->
                    Nothing
        )
        (demandsOf target graph)


{-| Returns the head annotation of every function-typed parameter on the head
arrow of each specialization of `target`.
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


{-| Returns the member of each singleton `LSet` among the annotations, in order,
skipping every other annotation.
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


{-| Tells whether an annotation is an `LSet` of exactly one member. No test uses
it.
-}
isSingleton : Mono.LambdaSetAnno -> Bool
isSingleton a =
    case a of
        Mono.LSet [ _ ] ->
            True

        _ ->
            False


{-| Tells whether an annotation is an `LSet` of at least two members. No test
uses it.
-}
isMulti : Mono.LambdaSetAnno -> Bool
isMulti a =
    case a of
        Mono.LSet ms ->
            List.length ms >= 2

        _ ->
            False


{-| Tells whether an annotation is anything but an `LSet` of more than `n`
members, so `LTop`, `LVar` and `LPartial` always pass.
-}
sizeAtMost : Int -> Mono.LambdaSetAnno -> Bool
sizeAtMost n a =
    case a of
        Mono.LSet ms ->
            List.length ms <= n

        _ ->
            True


{-| Returns the member count of an `LSet`, and a negative code for any other
annotation: -1 for `LVar`, -2 for `LTop` and -3 for `LPartial`. No test uses
it.
-}
annoSize : Mono.LambdaSetAnno -> Int
annoSize a =
    case a of
        Mono.LSet ms ->
            List.length ms

        Mono.LVar _ ->
            -1

        Mono.LTop _ ->
            -2

        Mono.LPartial _ ->
            -3


{-| Tells whether an annotation is anything but an `LSet` of fewer than two
members: it is `False` only for such an `LSet`.
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


{-| Renders annotations for a failure message, each as its constructor name with
the `LVar` number or the member count of an `LSet` or `LPartial`.
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
