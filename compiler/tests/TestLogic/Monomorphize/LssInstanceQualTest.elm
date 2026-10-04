module TestLogic.Monomorphize.LssInstanceQualTest exposing (suite)

{-| Tests that a source lambda inside a let-bound function gets a separate
member id in each instance of that function.

Under lambda-set specialization (LSS), the solver engine annotates a function
type with a _lambda set_. An `LSet` annotation lists, each by an interned
integer _member id_, the functions a value of that type may be. If the
instances shared one id, a call through that lambda would see a singleton set
`LSet [m]` standing for closures with different bodies, and
`Compiler.GlobalOpt.AbiCloning`, whose fingerprint check declines a set whose
closures differ, would leave the call as a generic dispatch.

A let-bound function that the solver engine meets at more than one type is
split into _local-multi instances_, `fold` and `fold$1`, numbered by an
ordinal from 0 (`Engine.recordLocalInstance`). Two types that differ only in a
lambda set give two instances. The body of each instance is translated again,
and with LSS on, as in each pipeline run here, under an _instance tag_ from
`Engine.localInstanceTagFor`: ordinal 0, and any ordinal at or past the
_instance cap_ `stamp.maxInstances` (where a cap of 0 means none), keeps the
tag of the enclosing instance, and any other ordinal gets that tag composed
with the ordinal by `Engine.mixTag`. Tag 0 means no instance. Where
`Engine.lambdaInstanceMemberId` interns a key for a lambda's member id, a
non-zero current tag is part of that key unless the lambda is folded onto its
global's own member id, so the copies of one source lambda in differently
tagged instances can get different ids.

The fixture, `foldShapeModule`, is a let-bound `fold` whose body passes a
lambda to the top-level `apply`, called once with `hashA` and once with
`hashB`. Tests 1 to 4 run the pipeline through `TestLogic.TestPipeline`'s
solver engine with LSS on and no global optimization. Tests 2 to 4 run it
twice, once with an instance cap of 1, which tags no instance, and once with
the default cap from `Compiler.Eco.Config.defaultLss`; test 1 runs only the
cap-1 arm. Member ids are interned integers whose values depend on the order
of interning, so the tests compare how many there are, not which they are.

The tests are numbered 1 to 4, 6 and 7; there is no test 5.

  - Test 1: at cap 1, the fixture's graph holds at least two closures that
    carry a member id, and at least two of those ids are equal.
  - Test 2: the fixture's graph has more distinct closure member ids at the
    default cap than at cap 1.
  - Test 3: the fixture's registry has more entries for a global named
    `apply` at the default cap than at cap 1.
  - Test 4: for `plainModule`, which has no let-bound function, the sorted
    closure member ids are the same at both caps.
  - Test 6: `mixTag` gives ordinal 1 different tags under the outer tags
    `mixTag 0 0` and `mixTag 0 1`.
  - Test 7: `mixTag 0 o` is not 0 for any `o` from 0 to 64.

Among what is not tested: whether `Compiler.GlobalOpt.AbiCloning` stamps the
calls once the ids are split; which closure carries the shared or split id;
caps other than 1 and the default; let-bound functions nested inside one
another, except through `mixTag` alone; and a lambda that is refused a tag
because it is folded onto its global's own member id.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , define
        , intExpr
        , lambdaExpr
        , letExpr
        , makeModuleWithTypedDefs
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import Compiler.Eco.Config as Config
import Compiler.MonoSolver.Engine as Engine
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The instance-qualification tests, described one by one in the module
docstring.
-}
suite : Test
suite =
    Test.describe "instance-qualified lambda members"
        [ Test.test "1. CAP=1: one source lambda in two local-multi instances shares ONE member id" <|
            \() ->
                -- Without a shared id at cap 1, test 2's comparison would show
                -- nothing about the tags.
                case runCollapsed foldShapeModule of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        let
                            members =
                                closureMembers g
                        in
                        if List.length members < 2 then
                            Expect.fail
                                ("fixture broken: expected >= 2 closure instances, got "
                                    ++ String.fromInt (List.length members)
                                )

                        else if List.length (distinct members) < List.length members then
                            Expect.pass

                        else
                            Expect.fail
                                ("expected a SHARED member id across instances, got all-distinct "
                                    ++ describeInts members
                                )
        , Test.test "2. the shared pair splits — one more DISTINCT member id" <|
            \() ->
                -- Counts, not ids: the integers depend on interning order and
                -- may differ between the two runs.
                case ( runCollapsed foldShapeModule, runWith foldShapeModule ) of
                    ( Ok offG, Ok onG ) ->
                        let
                            off =
                                List.length (distinct (closureMembers offG))

                            on =
                                List.length (distinct (closureMembers onG))
                        in
                        if on > off then
                            Expect.pass

                        else
                            Expect.fail
                                ("expected the instances to split, got distinct members off="
                                    ++ String.fromInt off
                                    ++ " on="
                                    ++ String.fromInt on
                                    ++ " (off ids "
                                    ++ describeInts (List.sort (closureMembers offG))
                                    ++ ", on ids "
                                    ++ describeInts (List.sort (closureMembers onG))
                                    ++ ")"
                                )

                    ( Err e, _ ) ->
                        Expect.fail e

                    ( _, Err e ) ->
                        Expect.fail e
        , Test.test "3. THE PAYOFF: distinct ids split the HOF's keyed specializations" <|
            \() ->
                -- Distinct member ids give `apply`'s function argument
                -- different lambda sets, and the spec key tells lambda sets
                -- apart, so `apply` can gain specializations.
                case ( runCollapsed foldShapeModule, runWith foldShapeModule ) of
                    ( Ok offG, Ok onG ) ->
                        let
                            off =
                                specCount "apply" offG

                            on =
                                specCount "apply" onG
                        in
                        if on > off then
                            Expect.pass

                        else
                            Expect.fail
                                ("expected the consumer to gain specializations, got off="
                                    ++ String.fromInt off
                                    ++ " on="
                                    ++ String.fromInt on
                                )

                    ( Err e, _ ) ->
                        Expect.fail e

                    ( _, Err e ) ->
                        Expect.fail e
        , Test.test "4. NO LOCAL-MULTI, NO CHANGE: a plain module is cap-identical" <|
            \() ->
                case ( runCollapsed plainModule, runWith plainModule ) of
                    ( Ok offG, Ok onG ) ->
                        Expect.equal (List.sort (closureMembers offG)) (List.sort (closureMembers onG))

                    ( Err e, _ ) ->
                        Expect.fail e

                    ( _, Err e ) ->
                        Expect.fail e
        , Test.test "6. mixTag composes rather than overwrites" <|
            \() ->
                Expect.notEqual
                    (Engine.mixTag (Engine.mixTag 0 0) 1)
                    (Engine.mixTag (Engine.mixTag 0 1) 1)
        , Test.test "7. mixTag never returns the no-instance sentinel" <|
            \() ->
                Expect.equal [] (List.filter (\o -> Engine.mixTag 0 o == 0) (List.range 0 64))
        ]



-- ====== FIXTURES ======


{-| The type `Int -> Int`, of the two hash functions and of `apply`'s function
parameter.
-}
hInt : Src.Type
hInt =
    tLambda (tType "Int" []) (tType "Int" [])


{-| A module holding one source lambda inside a let-bound function that is
used at two instances.

Its `testValue` is `fold hashA + fold hashB`, where the unannotated
`fold hashOf = apply (\t -> hashOf t) 3` is let-bound, `hashA` and `hashB` are
two different `Int -> Int` functions, and `apply f n = f n`. Both uses of
`fold` have the type `(Int -> Int) -> Int`, and differ only in the lambda set
of `hashOf`, so `fold` has two local-multi instances, and each of them passes
its own copy of the lambda to `apply`.

-}
foldShapeModule : Src.Module
foldShapeModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "hashA"
          , args = [ pVar "x" ]
          , tipe = hInt
          , body = binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "x")
          }
        , { name = "hashB"
          , args = [ pVar "x" ]
          , tipe = hInt
          , body = binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1)
          }
        , { name = "apply"
          , args = [ pVar "f", pVar "n" ]
          , tipe = tLambda hInt hInt
          , body = callExpr (varExpr "f") [ varExpr "n" ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                letExpr
                    [ define "fold"
                        [ pVar "hashOf" ]
                        (callExpr (varExpr "apply")
                            [ lambdaExpr [ pVar "t" ] (callExpr (varExpr "hashOf") [ varExpr "t" ])
                            , intExpr 3
                            ]
                        )
                    ]
                    (binopsExpr
                        [ ( callExpr (varExpr "fold") [ varExpr "hashA" ], "+" ) ]
                        (callExpr (varExpr "fold") [ varExpr "hashB" ])
                    )
          }
        ]


{-| A module that passes a lambda to `apply` with no let-bound function, so it
has no local-multi instance and nothing for an instance tag to split.
-}
plainModule : Src.Module
plainModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "apply"
          , args = [ pVar "f", pVar "n" ]
          , tipe = tLambda hInt hInt
          , body = callExpr (varExpr "f") [ varExpr "n" ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                callExpr (varExpr "apply")
                    [ lambdaExpr [ pVar "t" ] (binopsExpr [ ( varExpr "t", "+" ) ] (intExpr 1))
                    , intExpr 3
                    ]
          }
        ]



-- ====== HARNESS ======


{-| Monomorphizes `srcModule` as `runWithMax` does, at the default instance
cap.
-}
runWith : Src.Module -> Result String Mono.MonoGraph
runWith srcModule =
    runWithMax Config.defaultLss.stamp.maxInstances srcModule


{-| Monomorphizes `srcModule` as `runWithMax` does, at an instance cap of 1,
under which no local-multi instance is tagged.
-}
runCollapsed : Src.Module -> Result String Mono.MonoGraph
runCollapsed srcModule =
    runWithMax 1 srcModule


{-| Monomorphizes `srcModule` with the solver engine, the default limits and
the default LSS settings except for the instance cap `maxInstances`, and
returns the graph without global optimization, or the pipeline's error.
-}
runWithMax : Int -> Src.Module -> Result String Mono.MonoGraph
runWithMax maxInstances srcModule =
    let
        defaults =
            Config.defaultLss

        stampDefaults =
            Config.defaultLss.stamp
    in
    Pipeline.runSolverMonoWithLimits Config.defaultLimits
        { defaults
            | enabled = True
            , stamp =
                { stampDefaults | maxInstances = maxInstances }
        }
        srcModule



-- ====== READERS ======


{-| Returns the member id of every closure in the graph that carries one,
nested closures included, with repeats and in no particular order.
-}
closureMembers : Mono.MonoGraph -> List Int
closureMembers (Mono.MonoGraph g) =
    Array.foldl
        (\maybeNode acc ->
            case maybeNode of
                Just node ->
                    List.foldl collectMembers acc (nodeExprsOf node)

                Nothing ->
                    acc
        )
        []
        g.nodes


{-| Returns the expression a node holds: the body of a definition or a tail
function, or the expression of a port. Other kinds of node give none.
-}
nodeExprsOf : Mono.MonoNode -> List Mono.MonoExpr
nodeExprsOf node =
    case node of
        Mono.MonoDefine e _ ->
            [ e ]

        Mono.MonoTailFunc _ e _ ->
            [ e ]

        Mono.MonoPortIncoming e _ ->
            [ e ]

        Mono.MonoPortOutgoing e _ ->
            [ e ]

        _ ->
            []


{-| Returns `acc` with the member id of every closure in `expr` that carries
one added to the front, nested closures included.
-}
collectMembers : Mono.MonoExpr -> List Int -> List Int
collectMembers expr acc =
    MonoTraverse.foldExpr
        (\e a ->
            case e of
                Mono.MonoClosure info _ _ ->
                    case info.lssMember of
                        Just m ->
                            m :: a

                        Nothing ->
                            a

                _ ->
                    a
        )
        acc
        expr


{-| Counts the registry entries still present whose global is named `target`,
in any module. Accessor entries are never counted.
-}
specCount : String -> Mono.MonoGraph -> Int
specCount target (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ name, _ ) ->
                    if name == target then
                        acc + 1

                    else
                        acc

                _ ->
                    acc
        )
        0
        g.registry.reverseMapping


{-| Returns the list with repeats removed, in no particular order.
-}
distinct : List Int -> List Int
distinct =
    List.foldl
        (\x acc ->
            if List.member x acc then
                acc

            else
                x :: acc
        )
        []


{-| Renders `xs` as a bracketed, comma-separated list for a failure message.
-}
describeInts : List Int -> String
describeInts xs =
    "[" ++ String.join "," (List.map String.fromInt xs) ++ "]"
