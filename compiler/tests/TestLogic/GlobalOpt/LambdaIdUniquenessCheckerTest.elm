module TestLogic.GlobalOpt.LambdaIdUniquenessCheckerTest exposing (suite)

{-| Pins the `MONO_019` checker,
`TestLogic.GlobalOpt.LambdaIdUniqueness.lambdaIdIssues`, on two hand-built
graphs, so that `TestLogic.GlobalOpt.LambdaIdUniquenessTest`, which runs it
over the catalogue, is known to report a repeated `lambdaId` when one appears.

Each graph has two specs, each defining the identity function on `String` as a
closure. The tests establish that the checker accepts the graph whose closures
are numbered 0 and 1, and that for the graph whose closures are both numbered
7 it reports exactly one issue, naming `MONO_019`, the id `#7` and the two
SpecIds `0, 1`.

Among what is not tested: closures nested inside other expressions, and more
than two closures sharing an id.

-}

import Array
import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Mono as Mono
import Data.BitSet as BitSet
import Dict
import Expect
import Test exposing (Test)
import TestLogic.GlobalOpt.LambdaIdUniqueness exposing (lambdaIdIssues)


{-| The two checks of the checker.
-}
suite : Test
suite =
    Test.describe "lambdaIdIssues on hand-built graphs"
        [ Test.test "checker accepts distinct lambdaIds" <|
            \_ ->
                Expect.equal [] (lambdaIdIssues "fixture" (graphWithIds 0 1))
        , Test.test "checker reports a lambdaId used in two specs" <|
            \_ ->
                case lambdaIdIssues "fixture" (graphWithIds 7 7) of
                    [ line ] ->
                        Expect.equal True
                            (String.contains "MONO_019" line
                                && String.contains "#7" line
                                && String.contains "SpecIds 0, 1" line
                            )

                    other ->
                        Expect.fail ("expected exactly one issue, got: " ++ String.join " | " other)
        ]


{-| The module every fixture closure's `lambdaId` is numbered in, so that two
closures given the same number share a `lambdaId`.
-}
home : ModuleName.Canonical
home =
    ModuleName.Canonical ( "author", "proj" ) "M"


{-| The type `String -> String`, used for both fixture specs and their closures.
-}
fnTy : Mono.MonoType
fnTy =
    Mono.mFunction Mono.topLegacy [ Mono.MString ] Mono.MString


{-| A spec defining the identity function on `String` as a closure numbered
`uid`.
-}
closureNode : Int -> Mono.MonoNode
closureNode uid =
    Mono.MonoDefine
        (Mono.MonoClosure
            { lambdaId = Mono.AnonymousLambda home uid
            , srcLambda = Nothing
            , lssMember = Nothing
            , captures = []
            , params = [ ( "x", Mono.MString ) ]
            , closureKind = Nothing
            , captureAbi = Nothing
            }
            (Mono.MonoVarLocal "x" Mono.MString)
            fnTy
        )
        fnTy


{-| A two-spec graph whose closures are numbered `a` and `b`.
-}
graphWithIds : Int -> Int -> Mono.MonoGraph
graphWithIds a b =
    Mono.MonoGraph
        { nodes = Array.fromList [ Just (closureNode a), Just (closureNode b) ]
        , main = Mono.StaticMain 0
        , registry =
            { nextId = 2
            , mapping = Mono.specKeyMapEmpty
            , reverseMapping =
                Array.fromList
                    [ Just ( Mono.Global home "f", fnTy )
                    , Just ( Mono.Global home "g", fnTy )
                    ]
            , countByGlobal = Dict.empty
            }
        , ctorShapes = Mono.layoutMapEmpty
        , nextLambdaIndex = 8
        , callEdges = Array.empty
        , specHasEffects = BitSet.empty
        , specValueUsed = BitSet.empty
        , ports = []
        , flagsDecoder = Nothing
        , lssMemberOrigins = Dict.empty
        , lssMemberKinds = Dict.empty
        , lssBlockedMembers = Dict.empty
        }
