module TestLogic.Monomorphize.PostSettleDevirtTest exposing (suite)

{-| Pins the post-settle devirtualization in `Compiler.GlobalOpt.AbiCloning`:
the rewrite of a call through a known top-level function or constructor into a
direct call of one specialization of it. Without these tests, a rewrite that
skipped its arity guard, or chose the wrong specialization, would turn a call
into a direct call of the wrong code.

A call's callee type carries a lambda-set annotation on its arrow. When that
annotation is `LSet [m]`, the only function value that can reach the call is
the member `m`. When the graph holds no closure instance of `m` and `m` is not
a blocked member, the call is a _no-instance_ site. In a graph with a member
origin, as each test's graph has, `declinedNoInstance` counts the no-instance
sites that the pass neither rewrites nor stamps. To stamp a call is to fill in
its dispatch information while leaving the callee as it is; no test here
stamps one. A graph's `lssMemberOrigins` says what a member that is not a
lambda stands for: `OriginGlobal` a top-level function, `OriginCtor` a
constructor. `Mono.eqLayout` compares two MonoTypes ignoring their lambda-set
annotations, so two types are _layout-equal_ when they differ at most in
those. How the pass chooses a specialization is stated in `AbiCloning`; these
tests check its outcomes.

Each test runs `AbiCloning.abiCloningPass True` over a graph built by `run`.
The `True` switches on the pass's census, extra diagnostic tallies that none
of the counters asserted here depends on. The graph is one `MonoDefine` whose
body is a list holding one call. The callee is the local variable `h`,
annotated `LSet [member]`, applied to integer literals. The graph holds no
closures, so every call is a no-instance site. The origin table maps `member`
to `targetGlobal`, and the registry entries are listed in SpecId order.
Registry types carry an unknown-set annotation, except `intFnMember`, which is
the site's own type.

  - An `OriginGlobal` member, a one-argument call, and one `Int -> Int` spec
    of the target: `devirtPost.fn` is 1, `devirtPost.ctor`,
    `devirtPost.noSpec` and `declinedNoInstance` are 0, and the callee becomes
    a `MonoVarGlobal` of SpecId 0.
  - The same with an `OriginCtor` member: `devirtPost.ctor` is 1,
    `devirtPost.fn` and `declinedNoInstance` are 0, and the callee becomes
    SpecId 0.
  - Under-application: the callee type takes two parameters in one stage and
    the call passes one. `devirtPost.fn` and `devirtPost.noSpec` are 0,
    `declinedNoInstance` is 1, and the callee is not rewritten.
  - No layout-equal spec: the target's only spec is `Float -> Float`.
    `devirtPost.noSpec` and `declinedNoInstance` are 1, `devirtPost.fn` is 0,
    and the callee is not rewritten.
  - Two layout-equal specs of the target and neither equal to the site's
    type: `devirtPost.ambiguous` and `declinedNoInstance` are 1,
    `devirtPost.fn` and `devirtPost.noSpec` are 0, and the callee is not
    rewritten. Specs of one global with equal layouts need not compute the
    same function, so the pass does not choose between them by SpecId.
  - Two layout-equal specs of the target, the higher-numbered one equal to the
    site's type: `devirtPost.fn` is 1, `devirtPost.ambiguous` is 0, and the
    callee is SpecId 2, not the lower SpecId 1.

Among what is not tested: members of other origins (partial applications,
kernels, accessors), over-application, a callee that is not a local variable,
two specs both equal to the site's type, the type given to the rewritten
callee, the pass with the census off or with no origins, and whether specs of
another global are considered (`otherGlobal`'s spec at SpecId 0 would not
change any outcome asserted here).

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


{-| The post-settle devirtualization tests, one per case in the module
docstring.
-}
suite : Test
suite =
    Test.describe "E9.5 post-settle fn-global/ctor devirt (AbiCloning)"
        [ Test.test "g|-origin, exact arity, matching spec: REWRITTEN to MonoVarGlobal of that spec" <|
            \() ->
                let
                    ( graph, stats ) =
                        run
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
                        run
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
                        run
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
                        run
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
        , Test.test "two same-layout specs, no exact match: AMBIGUOUS, not rewritten" <|
            \() ->
                let
                    ( graph, stats ) =
                        run
                            (origins [ ( member, Mono.OriginGlobal targetGlobal ) ])
                            (registryOf
                                [ Just ( otherGlobal, intFnPlain ) -- spec 0: different global
                                , Just ( targetGlobal, intFnPlain ) -- spec 1: layout match
                                , Just ( targetGlobal, intFnPlain ) -- spec 2: same layout, higher id
                                ]
                            )
                            [ callSite 1 intRet ]
                in
                Expect.all
                    [ \( _, s ) -> Expect.equal 0 s.devirtPost.fn
                    , \( _, s ) -> Expect.equal 1 s.devirtPost.ambiguous
                    , \( _, s ) -> Expect.equal 0 s.devirtPost.noSpec
                    , \( _, s ) -> Expect.equal 1 s.declinedNoInstance
                    , \( g, _ ) -> Expect.equal Nothing (firstCalleeSpec g)
                    ]
                    ( graph, stats )
        , Test.test "two same-layout specs, one EXACT match at the higher id: exactness wins" <|
            \() ->
                let
                    ( graph, stats ) =
                        run
                            (origins [ ( member, Mono.OriginGlobal targetGlobal ) ])
                            (registryOf
                                [ Just ( otherGlobal, intFnPlain ) -- spec 0: different global
                                , Just ( targetGlobal, intFnPlain ) -- spec 1: layout match only
                                , Just ( targetGlobal, intFnMember ) -- spec 2: EXACT match, higher id
                                ]
                            )
                            [ callSite 1 intRet ]
                in
                Expect.all
                    [ \( _, s ) -> Expect.equal 1 s.devirtPost.fn
                    , \( _, s ) -> Expect.equal 0 s.devirtPost.ambiguous
                    , \( g, _ ) -> Expect.equal (Just 2) (firstCalleeSpec g)
                    ]
                    ( graph, stats )
        ]



-- ====== FIXTURE MACHINERY ======


{-| The member id the call's callee is annotated with. No closure in any
fixture graph carries it.
-}
member : Int
member =
    99991


{-| The module that the fixture globals and `dummyClosure`'s lambda belong to.
-}
home : ModuleName.Canonical
home =
    ModuleName.Canonical ( "author", "proj" ) "M"


{-| The global that `member` stands for in every test, whose specs the pass
chooses among.
-}
targetGlobal : Mono.Global
targetGlobal =
    Mono.Global home "target"


{-| A second global, whose spec sits at SpecId 0 in the two tests with several
specs.
-}
otherGlobal : Mono.Global
otherGlobal =
    Mono.Global home "other"


{-| The result type of every fixture call.
-}
intRet : Mono.MonoType
intRet =
    Mono.MInt


{-| `Int -> Int` annotated `LSet [member]`: the callee type of a one-argument
call. As a registry entry, it is the spec equal to the site's type.
-}
intFnMember : Mono.MonoType
intFnMember =
    Mono.mFunction (Mono.LSet [ member ]) [ Mono.MInt ] Mono.MInt


{-| `Int -> Int` with an unknown-set annotation: a spec type layout-equal to
`intFnMember` but not equal to it.
-}
intFnPlain : Mono.MonoType
intFnPlain =
    Mono.mFunction Mono.topLegacy [ Mono.MInt ] Mono.MInt


{-| `Float -> Float` with an unknown-set annotation: a spec type that is not
layout-equal to the site's.
-}
floatFn : Mono.MonoType
floatFn =
    Mono.mFunction Mono.topLegacy [ Mono.MFloat ] Mono.MFloat


{-| A two-parameter spec type, `Int -> Int -> Int` with both parameters in one
stage and an unknown-set annotation.
-}
intFn2 : Mono.MonoType
intFn2 =
    Mono.mFunction Mono.topLegacy [ Mono.MInt, Mono.MInt ] Mono.MInt


{-| The callee type of the under-application call: two parameters in one stage,
annotated `LSet [member]`.
-}
intFn2use : Mono.MonoType
intFn2use =
    Mono.mFunction (Mono.LSet [ member ]) [ Mono.MInt, Mono.MInt ] Mono.MInt


{-| Builds the call `callSiteTyped` builds, with the callee typed `intFnMember`.
-}
callSite : Int -> Mono.MonoType -> Mono.MonoExpr
callSite argCount retTy =
    callSiteTyped argCount intFnMember retTy


{-| Builds a call of the local variable `h`, typed `calleeTy`, applied to
`argCount` copies of the literal `1`, with result type `retTy` and default call
info.
-}
callSiteTyped : Int -> Mono.MonoType -> Mono.MonoType -> Mono.MonoExpr
callSiteTyped argCount calleeTy retTy =
    Mono.MonoCall A.zero
        (Mono.MonoVarLocal "h" calleeTy)
        (List.repeat argCount (Mono.MonoLiteral (Mono.LInt 1) Mono.MInt))
        retTy
        Mono.defaultCallInfo


{-| A closure instance of an unrelated member, 424242. No test uses it.
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


{-| Builds a member-origin table from (member, origin) pairs.
-}
origins : List ( Int, Mono.MemberOrigin ) -> Dict.Dict Int Mono.MemberOrigin
origins =
    Dict.fromList


{-| Builds a specialization registry in which entry i of `entries` is SpecId i
and `Nothing` is an empty slot. Only `reverseMapping` and `nextId` are filled.
-}
registryOf : List (Maybe ( Mono.Global, Mono.MonoType )) -> Mono.SpecializationRegistry
registryOf entries =
    { nextId = List.length entries
    , mapping = Mono.specKeyMapEmpty
    , reverseMapping = Array.fromList entries
    , countByGlobal = Dict.empty
    }


{-| Returns the SpecId of the first call whose callee is a `MonoVarGlobal`, among
the calls in the list body of the graph's first node, or `Nothing` when there
is none. A first node of any other shape than the one `run` builds also gives
`Nothing`.
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


{-| Runs `AbiCloning.abiCloningPass`, with the census on, over a graph whose one
node is a `MonoDefine` with a list of `exprs` as its body, carrying
`memberOrigins` and `registry`. Returns the rewritten graph and the pass's
statistics. The graph has no blocked members and no member kinds.
-}
run : Dict.Dict Int Mono.MemberOrigin -> Mono.SpecializationRegistry -> List Mono.MonoExpr -> ( Mono.MonoGraph, AbiCloning.AbiCloningStats )
run memberOrigins registry exprs =
    AbiCloning.abiCloningPass True
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
