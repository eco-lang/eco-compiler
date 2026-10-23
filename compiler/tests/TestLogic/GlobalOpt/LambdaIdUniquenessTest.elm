module TestLogic.GlobalOpt.LambdaIdUniquenessTest exposing (suite)

{-| MONO_019: within one `MonoGraph` no two `MonoClosure` nodes share a
`lambdaId`. Code generation names a nested closure's function after its
`lambdaId`, so a repeat would be two functions under one symbol.

`suite` gives every program that `SourceIR.Suite.StandardTestSuites` gathers
to `TestLogic.GlobalOpt.LambdaIdUniqueness.expectLambdaIdUniqueness`, which
checks the graph after monomorphization, after the global optimizer, and after
CAF hoisting run on that, and fails on any `lambdaId` found twice. Two
hand-built graphs check the checker itself: one with distinct ids, which it
must accept, and one with an id used in two specs, which it must report.

Among what is not tested: `ClosureInfo.srcLambda`, which may repeat by design;
programs outside the standard catalogue; graphs after CSE, which is off by
default.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.BitSet as BitSet
import Compiler.Elm.ModuleName as ModuleName
import Dict
import Expect
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.GlobalOpt.LambdaIdUniqueness exposing (expectLambdaIdUniqueness, lambdaIdIssues)


{-| The MONO_019 check over the standard catalogue, and the two checks of the
checker.
-}
suite : Test
suite =
    Test.describe "LambdaId uniqueness (MONO_019)"
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
        , StandardTestSuites.expectSuite expectLambdaIdUniqueness "has unique lambdaIds"
        ]


home : ModuleName.Canonical
home =
    ModuleName.Canonical ( "author", "proj" ) "M"


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
        , main = Nothing
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
