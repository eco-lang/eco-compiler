module TestLogic.Monomorphize.PostSettleDevirtTest exposing (suite)

{-| E9.5 — post-settle fn-global/ctor devirt, unit pins
(`plans/lss-post-settle-fn-global-devirt.md` §4.2).

The pass is driven directly on hand-built `MonoGraph`s holding ONE
consulting singleton call site whose member has NO closure instance (the
`noInstance` arm) plus a registry/origins pair describing the standalone
target:

1.  g|-origin, plain-var callee, exact arity, eqLayout spec exists →
    REWRITTEN to a direct `MonoVarGlobal` call of that spec
    (`devirtPostFn`), and `declinedNoInstance` stays 0 — the graph pin
    checks the callee node itself, not just the counter.
2.  The ctor half: c|-origin → same rewrite, counted `devirtPostCtor`.
3.  Arity mismatch (under-application) → NOT a candidate; ordinary
    `declinedNoInstance`.
4.  No eqLayout spec (target only has a Float-layout spec) →
    `devirtPostNoSpec` + `declinedNoInstance` (the fall-through keeps the
    historical counter meaning).
5.  Flag OFF → byte-identical graph, all E9.5 counters 0 (the substrate
    inertness pin).
6.  Two same-layout specs → the MINIMUM SpecId wins (determinism — the
    registry inversion's list order is arbitrary).

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.BitSet as BitSet
import Compiler.Elm.ModuleName as ModuleName
import Compiler.GlobalOpt.AbiCloning as AbiCloning
import Compiler.Reporting.Annotation as A
import Dict
import Expect
import Test exposing (Test)


suite : Test
suite =
    Test.describe "E9.5 post-settle fn-global/ctor devirt (AbiCloning)"
        [ Test.test "g|-origin, exact arity, matching spec: REWRITTEN to MonoVarGlobal of that spec" <|
            \() ->
                let
                    ( graph, stats ) =
                        run True
                            (origins [ ( member, Mono.OriginGlobal targetGlobal ) ])
                            (registryOf [ Just ( targetGlobal, intFnPlain ) ])
                            [ callSite 1 intRet ]
                in
                Expect.all
                    [ \( _, s ) -> Expect.equal 1 s.devirtPost.fn
                    , \( _, s ) -> Expect.equal 0 s.devirtPost.ctor
                    , \( _, s ) -> Expect.equal 0 s.devirtPost.noSpec
                    , \( _, s ) -> Expect.equal 0 s.declinedNoInstance
                    , \( g, _ ) -> Expect.equal (Just 0) (firstCalleeSpec g)
                    ]
                    ( graph, stats )
        , Test.test "c|-origin (ctor): same rewrite, counted on the ctor side" <|
            \() ->
                let
                    ( graph, stats ) =
                        run True
                            (origins [ ( member, Mono.OriginCtor targetGlobal ) ])
                            (registryOf [ Just ( targetGlobal, intFnPlain ) ])
                            [ callSite 1 intRet ]
                in
                Expect.all
                    [ \( _, s ) -> Expect.equal 0 s.devirtPost.fn
                    , \( _, s ) -> Expect.equal 1 s.devirtPost.ctor
                    , \( _, s ) -> Expect.equal 0 s.declinedNoInstance
                    , \( g, _ ) -> Expect.equal (Just 0) (firstCalleeSpec g)
                    ]
                    ( graph, stats )
        , Test.test "under-application: not a candidate — ordinary noInstance decline" <|
            \() ->
                let
                    ( graph, stats ) =
                        run True
                            (origins [ ( member, Mono.OriginGlobal targetGlobal ) ])
                            (registryOf [ Just ( targetGlobal, intFn2 ) ])
                            [ callSiteTyped 1 intFn2use intRet ]
                in
                Expect.all
                    [ \( _, s ) -> Expect.equal 0 s.devirtPost.fn
                    , \( _, s ) -> Expect.equal 0 s.devirtPost.noSpec
                    , \( _, s ) -> Expect.equal 1 s.declinedNoInstance
                    , \( g, _ ) -> Expect.equal Nothing (firstCalleeSpec g)
                    ]
                    ( graph, stats )
        , Test.test "no eqLayout spec: devirtPostNoSpec + the ordinary decline" <|
            \() ->
                let
                    ( graph, stats ) =
                        run True
                            (origins [ ( member, Mono.OriginGlobal targetGlobal ) ])
                            (registryOf [ Just ( targetGlobal, floatFn ) ])
                            [ callSite 1 intRet ]
                in
                Expect.all
                    [ \( _, s ) -> Expect.equal 0 s.devirtPost.fn
                    , \( _, s ) -> Expect.equal 1 s.devirtPost.noSpec
                    , \( _, s ) -> Expect.equal 1 s.declinedNoInstance
                    , \( g, _ ) -> Expect.equal Nothing (firstCalleeSpec g)
                    ]
                    ( graph, stats )
        , Test.test "flag OFF: pass walks (dummy instance in the index), site declines noInstance, NO rewrite (substrate inertness)" <|
            \() ->
                let
                    -- The dummy closure keeps the index non-empty so the
                    -- flag-off arm takes the REAL walk (the empty-index
                    -- early-exit would satisfy this pin vacuously).
                    ( graph, stats ) =
                        run False
                            (origins [ ( member, Mono.OriginGlobal targetGlobal ) ])
                            (registryOf [ Just ( targetGlobal, intFnPlain ) ])
                            [ dummyClosure, callSite 1 intRet ]
                in
                Expect.all
                    [ \( _, s ) -> Expect.equal 0 s.devirtPost.fn
                    , \( _, s ) -> Expect.equal 0 s.devirtPost.ctor
                    , \( _, s ) -> Expect.equal 0 s.devirtPost.noSpec
                    , \( _, s ) -> Expect.equal 1 s.declinedNoInstance
                    , \( g, _ ) -> Expect.equal Nothing (firstCalleeSpec g)
                    ]
                    ( graph, stats )
        , Test.test "two same-layout specs: the MINIMUM SpecId wins (determinism)" <|
            \() ->
                let
                    ( graph, stats ) =
                        run True
                            (origins [ ( member, Mono.OriginGlobal targetGlobal ) ])
                            (registryOf
                                [ Just ( otherGlobal, intFnPlain ) -- spec 0: different global
                                , Just ( targetGlobal, intFnPlain ) -- spec 1: FIRST match
                                , Just ( targetGlobal, intFnPlain ) -- spec 2: same layout, higher id
                                ]
                            )
                            [ callSite 1 intRet ]
                in
                Expect.all
                    [ \( _, s ) -> Expect.equal 1 s.devirtPost.fn
                    , \( g, _ ) -> Expect.equal (Just 1) (firstCalleeSpec g)
                    ]
                    ( graph, stats )
        ]



-- ====== FIXTURE MACHINERY ======


member : Int
member =
    99991


home : ModuleName.Canonical
home =
    ModuleName.Canonical ( "author", "proj" ) "M"


targetGlobal : Mono.Global
targetGlobal =
    Mono.Global home "target"


otherGlobal : Mono.Global
otherGlobal =
    Mono.Global home "other"


intRet : Mono.MonoType
intRet =
    Mono.MInt


{-| The site's callee type: `(Int -> Int) {member}`.
-}
intFnMember : Mono.MonoType
intFnMember =
    Mono.mFunction (Mono.LSet [ member ]) [ Mono.MInt ] Mono.MInt


{-| The registry spec's stored type: same layout, no annotation
(`eqLayout` is annotation-blind — that is the point of the fixture).
-}
intFnPlain : Mono.MonoType
intFnPlain =
    Mono.mFunction Mono.topLegacy [ Mono.MInt ] Mono.MInt


floatFn : Mono.MonoType
floatFn =
    Mono.mFunction Mono.topLegacy [ Mono.MFloat ] Mono.MFloat


{-| A 2-parameter target (for the under-application pin): the value's type
at the site still shows both remaining params, the site passes ONE arg.
-}
intFn2 : Mono.MonoType
intFn2 =
    Mono.mFunction Mono.topLegacy [ Mono.MInt, Mono.MInt ] Mono.MInt


intFn2use : Mono.MonoType
intFn2use =
    Mono.mFunction (Mono.LSet [ member ]) [ Mono.MInt, Mono.MInt ] Mono.MInt


callSite : Int -> Mono.MonoType -> Mono.MonoExpr
callSite argCount retTy =
    callSiteTyped argCount intFnMember retTy


callSiteTyped : Int -> Mono.MonoType -> Mono.MonoType -> Mono.MonoExpr
callSiteTyped argCount calleeTy retTy =
    Mono.MonoCall A.zero
        (Mono.MonoVarLocal "h" calleeTy)
        (List.repeat argCount (Mono.MonoLiteral (Mono.LInt 1) Mono.MInt))
        retTy
        Mono.defaultCallInfo


{-| An unrelated closure instance (different member id) whose only job is
keeping AbiCloning's index non-empty in the flag-off pin.
-}
dummyClosure : Mono.MonoExpr
dummyClosure =
    Mono.MonoClosure
        { lambdaId = Mono.AnonymousLambda home 7
        , srcLambda = Nothing
        , lssMember = Just 424242
        , captures = []
        , params = [ ( "x", Mono.MInt ) ]
        , closureKind = Nothing
        , captureAbi = Nothing
        }
        (Mono.MonoVarLocal "x" Mono.MInt)
        (Mono.mFunction (Mono.LSet [ 424242 ]) [ Mono.MInt ] Mono.MInt)


origins : List ( Int, Mono.MemberOrigin ) -> Dict.Dict Int Mono.MemberOrigin
origins =
    Dict.fromList


registryOf : List (Maybe ( Mono.Global, Mono.MonoType )) -> Mono.SpecializationRegistry
registryOf entries =
    { nextId = List.length entries
    , mapping = Mono.specKeyMapEmpty
    , reverseMapping = Array.fromList entries
    , countByGlobal = Dict.empty
    }


{-| The SpecId of the first `MonoVarGlobal`-callee call found in the graph's
single node, `Nothing` when the callee is still the local var — the pin that
the REWRITE happened (or provably did not).
-}
firstCalleeSpec : Mono.MonoGraph -> Maybe Int
firstCalleeSpec (Mono.MonoGraph record) =
    case Array.get 0 record.nodes of
        Just (Just (Mono.MonoDefine (Mono.MonoList _ exprs _) _)) ->
            List.head
                (List.filterMap
                    (\e ->
                        case e of
                            Mono.MonoCall _ (Mono.MonoVarGlobal _ specId _) _ _ _ ->
                                Just specId

                            _ ->
                                Nothing
                    )
                    exprs
                )

        _ ->
            Nothing


run : Bool -> Dict.Dict Int Mono.MemberOrigin -> Mono.SpecializationRegistry -> List Mono.MonoExpr -> ( Mono.MonoGraph, AbiCloning.AbiCloningStats )
run flag memberOrigins registry exprs =
    AbiCloning.abiCloningPass True
        flag
        False
        True
        False
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
            , registry = registry
            , ctorShapes = Mono.layoutMapEmpty
            , nextLambdaIndex = 100
            , callEdges = Array.empty
            , specHasEffects = BitSet.empty
            , specValueUsed = BitSet.empty
            , ports = []
            , flagsDecoder = Nothing
            , lssMemberOrigins = memberOrigins
            , lssMemberKinds = Dict.empty
            , lssBlockedMembers = Dict.empty
            }
        )
