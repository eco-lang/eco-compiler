module TestLogic.Monomorphize.LssInstanceQualTest exposing (suite)

{-| INSTANCE-QUALIFIED LAMBDA MEMBERS
(`plans/lss-instance-qualified-members.md`).

Local-multi instance keying is annotation-SENSITIVE
(`Engine.recordMultiInstance`): a let-bound function applied at two types that
differ only in a lambda set mints `f` and `f$1`, and `buildLocalDefs`
re-translates its RHS once per instance. Lambda member qualification was NOT
instance-aware: both re-translations happen inside ONE spec of the enclosing
global, so a lambda in that RHS minted the SAME member id in both.

The consumer then sees a singleton `LSet [m]` indexing two behaviourally
different bodies. AbiCloning refuses to stamp it (LSS\_024's fingerprint fence,
`declinedBodyMismatch`) — correctly, because stamping would be the E11
representative hijack — and the call stays a generic dispatch.

These pins are a DIFFERENTIAL: the same fixture flag-off and flag-on. Flag-off
pins today's collapse (so the differential is real, not a tautology), flag-on
pins the split and the keyed spec fan-out it unlocks.

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


suite : Test
suite =
    Test.describe "instance-qualified lambda members"
        [ Test.test "1. CAP=1: one source lambda in two local-multi instances shares ONE member id" <|
            \() ->
                -- Pins the collapsed arm, so test 2's differential is not
                -- vacuous. `maxInstances = 1` tags nothing (ordinal 0 is never
                -- tagged and ordinals at or past the cap take today's key), so
                -- it reproduces exactly what `lss.stamp.enabled = False` used
                -- to produce before that flag was removed (2026-09-18).
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
                -- Id-count, not id-identity: interning is order-dependent, so
                -- the integers themselves move between arms. What is stable is
                -- that one member id becomes two. Measured 5 -> 6 distinct.
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
                -- §1.2's chain, end to end: distinct members => distinct
                -- annotations at the callback position => different specHashOf
                -- => `keyed` splits the consumer. Without this step the id
                -- split buys nothing.
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
                -- The mechanism must be inert where nothing splits — otherwise
                -- the corpus-wide fan-out cost is paid for nothing.
                case ( runCollapsed plainModule, runWith plainModule ) of
                    ( Ok offG, Ok onG ) ->
                        Expect.equal (List.sort (closureMembers offG)) (List.sort (closureMembers onG))

                    ( Err e, _ ) ->
                        Expect.fail e

                    ( _, Err e ) ->
                        Expect.fail e
        , Test.test "6. mixTag composes rather than overwrites" <|
            \() ->
                -- §3.2: inner ordinal 1 under outer 0 must not collide with
                -- inner ordinal 1 under outer 1.
                Expect.notEqual
                    (Engine.mixTag (Engine.mixTag 0 0) 1)
                    (Engine.mixTag (Engine.mixTag 0 1) 1)
        , Test.test "7. mixTag never returns the no-instance sentinel" <|
            \() ->
                Expect.equal [] (List.filter (\o -> Engine.mixTag 0 o == 0) (List.range 0 64))
        ]



-- ====== FIXTURES ======


hInt : Src.Type
hInt =
    tLambda (tType "Int" []) (tType "Int" [])


{-| `Compiler/AST/Monomorphized.elm`'s `mRecord`, reduced: ONE source lambda,
inside a LET-bound helper parameterised by a function, applied twice with
different functions. The two applications have the same type modulo the lambda
set of `hashOf`, which is exactly what local-multi splits on and what member
qualification did not.
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


{-| No let-bound function, so nothing to instance-qualify.
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


runWith : Src.Module -> Result String Mono.MonoGraph
runWith srcModule =
    runWithMax Config.defaultLss.stamp.maxInstances srcModule


{-| The COLLAPSED arm: `maxInstances = 1` tags nothing, which is what
`lss.stamp.enabled = False` produced before that flag was fixed at its default
and removed (2026-09-18).
-}
runCollapsed : Src.Module -> Result String Mono.MonoGraph
runCollapsed srcModule =
    runWithMax 1 srcModule


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
                -- Record UPDATE, not a literal: a literal breaks the moment
                -- `LssStampConfig` gains a field, and nothing here would say so
                -- until a self-build.
                { stampDefaults | maxInstances = maxInstances }
        }
        srcModule



-- ====== READERS ======


{-| Every `MonoClosure`'s `lssMember`, over the whole graph.
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


describeInts : List Int -> String
describeInts xs =
    "[" ++ String.join "," (List.map String.fromInt xs) ++ "]"
