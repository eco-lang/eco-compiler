module TestLogic.Monomorphize.AbiCloningFenceTest exposing (suite)

{-| LSS_024 — the AbiCloning fingerprint fence (F), unit pins
(`plans/lss-layout-qualified-members.md` §5.3).

The pass is driven directly on hand-built `MonoGraph`s holding two closure
instances of ONE member id plus one consulting singleton call site:

1.  VERBATIM clones, equal layouts → one multi group, fingerprint-equal →
    the site STAMPS (`dispatchUpgraded`) — sharing an id across verbatim
    clones keeps fast dispatch.
2.  An E11-SHAPED pair — same layouts, bodies differing ONLY in which
    member id an inner annotation names → `bodyMismatch` decline. THE
    soundness pin of the plan's §1.2: under id sharing, behaviorally
    divergent same-layout clones must never rep-stamp (the recorded
    representative-hijack SIGSEGV class).
3.  A capture-layout-divergent pair → the existing `abiMismatch` fence,
    unchanged (and, by laziness, no fingerprint is even computed there).

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.BitSet as BitSet
import Compiler.GlobalOpt.AbiCloning as AbiCloning
import Compiler.Reporting.Annotation as A
import Dict
import Expect
import System.TypeCheck.IO as IO
import Test exposing (Test)


suite : Test
suite =
    Test.describe "LSS_024 fingerprint fence (AbiCloning)"
        [ Test.test "verbatim clones under one member: multi group, fingerprints agree, site STAMPS" <|
            \() ->
                let
                    stats =
                        statsOf
                            [ mkClosure 1 member [] plainBody plainRet
                            , mkClosure 2 member [] plainBody plainRet
                            , callSite plainRet
                            ]
                in
                Expect.all
                    [ \s -> Expect.equal 1 s.dispatchUpgraded
                    , \s -> Expect.equal 0 s.declinedBodyMismatch
                    , \s -> Expect.equal 0 s.declinedAbiMismatch
                    , \s -> Expect.equal 1 s.multiInstanceGroups
                    ]
                    stats
        , Test.test "E11-shaped pair (inner annotation names a different member): bodyMismatch decline" <|
            \() ->
                let
                    stats =
                        statsOf
                            [ mkClosure 1 member [] (annoBody 777) (annoRet 777)
                            , mkClosure 2 member [] (annoBody 778) (annoRet 778)
                            , callSite (intFn Mono.LTop)
                            ]
                in
                Expect.all
                    [ \s -> Expect.equal 0 s.dispatchUpgraded
                    , \s -> Expect.equal 1 s.declinedBodyMismatch
                    , \s -> Expect.equal 0 s.declinedAbiMismatch
                    , \s -> Expect.equal 1 s.multiInstanceGroups
                    ]
                    stats
        , Test.test "fence OFF: the E11-shaped pair STAMPS (documented flag-off/HEAD behavior, id-inequality doctrine)" <|
            \() ->
                let
                    stats =
                        statsWithFence False
                            [ mkClosure 1 member [] (annoBody 777) (annoRet 777)
                            , mkClosure 2 member [] (annoBody 778) (annoRet 778)
                            , callSite (intFn Mono.LTop)
                            ]
                in
                Expect.all
                    [ \s -> Expect.equal 1 s.dispatchUpgraded
                    , \s -> Expect.equal 0 s.declinedBodyMismatch
                    ]
                    stats
        , Test.test "capture-layout-divergent pair: abiMismatch (existing fence unchanged)" <|
            \() ->
                let
                    stats =
                        statsOf
                            [ mkClosure 1 member [ ( "c", Mono.MonoLiteral (Mono.LInt 1) Mono.MInt, False ) ] plainBody plainRet
                            , mkClosure 2 member [ ( "c", Mono.MonoLiteral (Mono.LStr "s") Mono.MString, False ) ] plainBody plainRet
                            , callSite plainRet
                            ]
                in
                Expect.all
                    [ \s -> Expect.equal 0 s.dispatchUpgraded
                    , \s -> Expect.equal 0 s.declinedBodyMismatch
                    , \s -> Expect.equal 1 s.declinedAbiMismatch
                    ]
                    stats
        ]



-- ====== FIXTURE MACHINERY ======


member : Int
member =
    99991


home : IO.Canonical
home =
    IO.Canonical ( "author", "proj" ) "M"


intFn : Mono.LambdaSetAnno -> Mono.MonoType
intFn anno =
    Mono.mFunction anno [ Mono.MInt ] Mono.MInt


{-| Case-1/3 body: `x` at Int — identical across clones.
-}
plainBody : Mono.MonoExpr
plainBody =
    Mono.MonoVarLocal "x" Mono.MInt


plainRet : Mono.MonoType
plainRet =
    Mono.MInt


{-| Case-2 body: a function-typed local whose arrow annotation names member
`mid` — layout-identical across clones, ANNOTATION-divergent. This is the
E11 shape: the compiled bodies differ only in which continuation their
inner site is committed to.
-}
annoBody : Int -> Mono.MonoExpr
annoBody mid =
    Mono.MonoVarLocal "k" (intFn (Mono.LSet [ mid ]))


annoRet : Int -> Mono.MonoType
annoRet mid =
    intFn (Mono.LSet [ mid ])


mkClosure : Int -> Int -> List ( String, Mono.MonoExpr, Bool ) -> Mono.MonoExpr -> Mono.MonoType -> Mono.MonoExpr
mkClosure uid mid captures body retTy =
    Mono.MonoClosure
        { lambdaId = Mono.AnonymousLambda home uid
        , srcLambda = Nothing
        , lssMember = Just mid
        , captures = captures
        , params = [ ( "x", Mono.MInt ) ]
        , closureKind = Nothing
        , captureAbi = Nothing
        }
        body
        (Mono.mFunction (Mono.LSet [ mid ]) [ Mono.MInt ] retTy)


{-| A consulting singleton call site: callee value of type
`(Int -> ret) {member}` applied to one Int.
-}
callSite : Mono.MonoType -> Mono.MonoExpr
callSite retTy =
    Mono.MonoCall A.zero
        (Mono.MonoVarLocal "h" (Mono.mFunction (Mono.LSet [ member ]) [ Mono.MInt ] retTy))
        [ Mono.MonoLiteral (Mono.LInt 1) Mono.MInt ]
        retTy
        Mono.defaultCallInfo


statsOf : List Mono.MonoExpr -> AbiCloning.AbiCloningStats
statsOf =
    statsWithFence True


{-| The pass with the LSS_024 fence toggled — `True` in every fence pin;
`False` documents the preserved flag-off (HEAD) behavior.
-}
statsWithFence : Bool -> List Mono.MonoExpr -> AbiCloning.AbiCloningStats
statsWithFence fence exprs =
    Tuple.second
        (AbiCloning.abiCloningPass fence False
            (Mono.MonoGraph
                { nodes =
                    Array.fromList
                        [ Just
                            (Mono.MonoDefine
                                (Mono.MonoList A.zero exprs (Mono.mList Mono.MInt))
                                (Mono.mList Mono.MInt)
                            )
                        ]
                , main = Nothing
                , registry =
                    { nextId = 0
                    , mapping = Mono.specKeyMapEmpty
                    , reverseMapping = Array.empty
                    , countByGlobal = Dict.empty
                    }
                , ctorShapes = Mono.layoutMapEmpty
                , nextLambdaIndex = 100
                , callEdges = Array.empty
                , specHasEffects = BitSet.empty
                , specValueUsed = BitSet.empty
                , ports = []
                , flagsDecoder = Nothing
                , lssMemberOrigins = Dict.empty
                , lssBlockedMembers = Dict.empty
                }
            )
        )
