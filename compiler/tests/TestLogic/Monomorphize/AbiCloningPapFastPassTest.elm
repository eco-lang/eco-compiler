module TestLogic.Monomorphize.AbiCloningPapFastPassTest exposing (suite)

{-| LSS\_040 at the PASS level — `lss.stamp.papFast`
(`plans/lss-pap-fast-stamp.md` §5).

A `p|<global>|<k>` member names a k-applied partial application of a global.
The fence on it forbids a DIRECT rewrite (that drops the bound arguments); a
FAST stamp keeps the heap object and loads the bound arguments out of it. These
pins drive the whole pass on hand-built graphs, in the `PostSettleDevirtTest`
mould, because the properties that matter are about WHICH sites get stamped and
WHAT the stamp says — and, for soundness, that the callee expression is never
touched.

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
    Test.describe "LSS_040 p| fast stamp at the pass level (lss.stamp.papFast)"
        [ Test.test "1. DIFFERENTIAL: a p| site declines flag-off and FAST-stamps flag-on, callee untouched" <|
            \() ->
                -- `add : Int -> Int -> Int`, the value is `add 5` (k = 1), the
                -- site applies the residual's one argument.
                let
                    reg =
                        registryOf [ Nothing, Just ( addGlobal, fn [ Mono.MInt, Mono.MInt ] Mono.MInt ) ]

                    nodes =
                        [ specClosure [ Mono.MInt, Mono.MInt ] Mono.MInt ]

                    site =
                        papSite 1 (fn1 [ Mono.MInt ] Mono.MInt) 1

                    offStats =
                        Tuple.second (run False (origins [ ( pap, Mono.OriginPap addGlobal 1 ) ]) reg nodes [ site ])

                    ( onGraph, onStats ) =
                        run True (origins [ ( pap, Mono.OriginPap addGlobal 1 ) ]) reg nodes [ site ]
                in
                Expect.all
                    [ \_ -> Expect.equal 0 offStats.stampedPapGlobal
                    , \_ -> Expect.equal 1 offStats.declinedNoInstance
                    , \_ -> Expect.equal 1 onStats.stampedPapGlobal
                    , \_ -> Expect.equal 0 onStats.declinedNoInstance

                    -- The stamp, field for field (§3.2).
                    , \_ -> Expect.equal (Just 1) (Maybe.andThen (\ci -> ci.fastPapPrefix) (firstCallInfo onGraph))
                    , \_ -> Expect.equal (Just 1) (Maybe.andThen (\ci -> ci.fastEvaluatorSpec) (firstCallInfo onGraph))
                    , \_ ->
                        Expect.equal
                            (Just { captureTypes = [ Mono.MInt ], paramTypes = [ Mono.MInt ], returnType = Mono.MInt })
                            (Maybe.andThen (\ci -> ci.captureAbi) (firstCallInfo onGraph))

                    -- §3.6: the sentinel is a uid no mint produces.
                    , \_ -> Expect.equal (Just (Mono.AnonymousLambda home -2)) (Maybe.andThen (\ci -> ci.fastEvaluator) (firstCallInfo onGraph))

                    -- SOUNDNESS: the callee is STILL the local var. A direct
                    -- rewrite to `MonoVarGlobal` is the recorded miscompile.
                    , \_ -> Expect.equal True (calleeIsLocal onGraph)
                    ]
                    ()
        , Test.test "2. P5 UNIQUENESS: two specs of the global with the same residual DECLINE (papAmbiguous)" <|
            \() ->
                -- `p|add|1` is layout-blind. `add : Int -> Int -> Int` and
                -- `add : Float -> Int -> Int` both have residual `Int -> Int`;
                -- their PAP objects hold an Int and a Float in slot 0. Stamping
                -- either would load slot 0 with the wrong kind.
                let
                    reg =
                        registryOf
                            [ Nothing
                            , Just ( addGlobal, fn [ Mono.MInt, Mono.MInt ] Mono.MInt )
                            , Just ( addGlobal, fn [ Mono.MFloat, Mono.MInt ] Mono.MInt )
                            ]

                    nodes =
                        [ specClosure [ Mono.MInt, Mono.MInt ] Mono.MInt
                        , specClosure [ Mono.MFloat, Mono.MInt ] Mono.MInt
                        ]

                    site =
                        papSite 1 (fn1 [ Mono.MInt ] Mono.MInt) 1

                    ( g, st ) =
                        run True (origins [ ( pap, Mono.OriginPap addGlobal 1 ) ]) reg nodes [ site ]
                in
                Expect.all
                    [ \_ -> Expect.equal 0 st.stampedPapGlobal
                    , \_ -> Expect.equal 1 st.declinedNoInstance
                    , \_ -> Expect.equal Nothing (Maybe.andThen (\ci -> ci.fastPapPrefix) (firstCallInfo g))
                    ]
                    ()
        , Test.test "3. P3 FUNCTION TARGET: a non-function spec node (CAF) DECLINES (papNonFn)" <|
            \() ->
                -- The registry's only spec of the global is a value node, not
                -- callable code. `specFunctionRow` is Nothing for it.
                let
                    reg =
                        registryOf [ Nothing, Just ( addGlobal, Mono.MInt ) ]

                    nodes =
                        [ Mono.MonoDefine (Mono.MonoLiteral (Mono.LInt 7) Mono.MInt) Mono.MInt ]

                    site =
                        papSite 1 (fn1 [ Mono.MInt ] Mono.MInt) 1

                    ( _, st ) =
                        run True (origins [ ( pap, Mono.OriginPap addGlobal 1 ) ]) reg nodes [ site ]
                in
                Expect.all
                    [ \_ -> Expect.equal 0 st.stampedPapGlobal
                    , \_ -> Expect.equal 1 st.declinedNoInstance
                    ]
                    ()
        , Test.test "4. P6 CHAR gate: an MChar in the k-prefix DECLINES (papChar)" <|
            \() ->
                let
                    reg =
                        registryOf [ Nothing, Just ( addGlobal, fn [ Mono.MChar, Mono.MInt ] Mono.MInt ) ]

                    nodes =
                        [ specClosure [ Mono.MChar, Mono.MInt ] Mono.MInt ]

                    site =
                        papSite 1 (fn1 [ Mono.MInt ] Mono.MInt) 1

                    ( _, st ) =
                        run True (origins [ ( pap, Mono.OriginPap addGlobal 1 ) ]) reg nodes [ site ]
                in
                Expect.equal 0 st.stampedPapGlobal
        , Test.test "5. P2 RESIDUAL PEEL: a curried residual applied flat is peeled and stamps with k=1, |params|=2" <|
            \() ->
                -- `add3 : Int -> Int -> Int -> Int`, value `add3 1` (k = 1).
                -- `Store.classifyGo` types the residual as `Int -> (Int -> Int)`
                -- — first stage 1 — while the site applies 2 args flat.
                let
                    reg =
                        registryOf [ Nothing, Just ( addGlobal, fn [ Mono.MInt, Mono.MInt, Mono.MInt ] Mono.MInt ) ]

                    nodes =
                        [ specClosure [ Mono.MInt, Mono.MInt, Mono.MInt ] Mono.MInt ]

                    curriedResidual =
                        fn1 [ Mono.MInt ] (Mono.mFunction Mono.topLegacy [ Mono.MInt ] Mono.MInt)

                    site =
                        papSite 2 curriedResidual 1

                    ( g, st ) =
                        run True (origins [ ( pap, Mono.OriginPap addGlobal 1 ) ]) reg nodes [ site ]
                in
                Expect.all
                    [ \_ -> Expect.equal 1 st.stampedPapGlobal
                    , \_ -> Expect.equal (Just 1) (Maybe.andThen (\ci -> ci.fastPapPrefix) (firstCallInfo g))
                    , \_ ->
                        Expect.equal
                            (Just { captureTypes = [ Mono.MInt ], paramTypes = [ Mono.MInt, Mono.MInt ], returnType = Mono.MInt })
                            (Maybe.andThen (\ci -> ci.captureAbi) (firstCallInfo g))
                    ]
                    ()
        , Test.test "6. P4 SHAPE: a return-layout mismatch DECLINES (papShapeMiss)" <|
            \() ->
                let
                    reg =
                        registryOf [ Nothing, Just ( addGlobal, fn [ Mono.MInt, Mono.MInt ] Mono.MFloat ) ]

                    nodes =
                        [ specClosure [ Mono.MInt, Mono.MInt ] Mono.MFloat ]

                    site =
                        papSite 1 (fn1 [ Mono.MInt ] Mono.MInt) 1

                    ( _, st ) =
                        run True (origins [ ( pap, Mono.OriginPap addGlobal 1 ) ]) reg nodes [ site ]
                in
                Expect.equal 0 st.stampedPapGlobal
        , Test.test "7. k=2: two bound arguments split the row at 2" <|
            \() ->
                -- `add3 4 5` (k = 2), residual `Int -> Int`.
                let
                    reg =
                        registryOf [ Nothing, Just ( addGlobal, fn [ Mono.MInt, Mono.MInt, Mono.MInt ] Mono.MInt ) ]

                    nodes =
                        [ specClosure [ Mono.MInt, Mono.MInt, Mono.MInt ] Mono.MInt ]

                    site =
                        papSite 1 (fn1 [ Mono.MInt ] Mono.MInt) 2

                    ( g, st ) =
                        run True (origins [ ( pap, Mono.OriginPap addGlobal 2 ) ]) reg nodes [ site ]
                in
                Expect.all
                    [ \_ -> Expect.equal 1 st.stampedPapGlobal
                    , \_ -> Expect.equal (Just 2) (Maybe.andThen (\ci -> ci.fastPapPrefix) (firstCallInfo g))
                    , \_ ->
                        Expect.equal
                            (Just { captureTypes = [ Mono.MInt, Mono.MInt ], paramTypes = [ Mono.MInt ], returnType = Mono.MInt })
                            (Maybe.andThen (\ci -> ci.captureAbi) (firstCallInfo g))
                    ]
                    ()
        , Test.test "8. §11.1 CONSTRUCTOR PAP: a MonoCtor spec within the typed-slot bound STAMPS" <|
            \() ->
                -- `Rect : Int -> Float -> Shape`, value `Rect 2` (k = 1). The
                -- ctor spec is a real func.func of its fields; the row is the
                -- field list and the return is the custom type.
                let
                    reg =
                        registryOf [ Nothing, Just ( rectGlobal, fn [ Mono.MInt, Mono.MFloat ] shapeTy ) ]

                    nodes =
                        [ ctorSpec [ Mono.MInt, Mono.MFloat ] ]

                    site =
                        papSite 1 (fn1 [ Mono.MFloat ] shapeTy) 1

                    ( g, st ) =
                        run True (origins [ ( pap, Mono.OriginPap rectGlobal 1 ) ]) reg nodes [ site ]
                in
                Expect.all
                    [ \_ -> Expect.equal 1 st.stampedPapGlobal
                    , \_ -> Expect.equal (Just 1) (Maybe.andThen (\ci -> ci.fastPapPrefix) (firstCallInfo g))
                    , \_ ->
                        Expect.equal
                            (Just { captureTypes = [ Mono.MInt ], paramTypes = [ Mono.MFloat ], returnType = shapeTy })
                            (Maybe.andThen (\ci -> ci.captureAbi) (firstCallInfo g))
                    , \_ -> Expect.equal True (calleeIsLocal g)
                    ]
                    ()
        , Test.test "9. §11.1 GUARD: a constructor wider than 24 fields DECLINES (tail fields are boxed)" <|
            \() ->
                -- `computeCtorLayout` leaves fields at index >= 24 boxed; the
                -- fast call would pass them unboxed. 25 Int fields, k = 1.
                let
                    fields =
                        List.repeat 25 Mono.MInt

                    reg =
                        registryOf [ Nothing, Just ( rectGlobal, fn fields shapeTy ) ]

                    nodes =
                        [ ctorSpec fields ]

                    site =
                        papSite 24 (fn1 (List.repeat 24 Mono.MInt) shapeTy) 1

                    ( _, st ) =
                        run True (origins [ ( pap, Mono.OriginPap rectGlobal 1 ) ]) reg nodes [ site ]
                in
                Expect.all
                    [ \_ -> Expect.equal 0 st.stampedPapGlobal
                    , \_ -> Expect.equal 1 st.declinedNoInstance
                    ]
                    ()
        ]



-- ====== FIXTURE MACHINERY ======


{-| The `p|add|k` member id.
-}
pap : Int
pap =
    99993


home : ModuleName.Canonical
home =
    ModuleName.Canonical ( "author", "proj" ) "M"


addGlobal : Mono.Global
addGlobal =
    Mono.Global home "add"


rectGlobal : Mono.Global
rectGlobal =
    Mono.Global home "Rect"


{-| The custom type a constructor spec returns. Any non-function layout will
do for these pins; `eqLayout` compares it against the site's return.
-}
shapeTy : Mono.MonoType
shapeTy =
    Mono.mList Mono.MFloat


{-| A registry SPEC node of a constructor: `MonoCtor shape ty`, the node kind
`specFunctionRow` reads the row off in §11.1 (fields = `shape.fieldTypes`,
return = the decomposed result of `ty`).
-}
ctorSpec : List Mono.MonoType -> Mono.MonoNode
ctorSpec fieldTys =
    Mono.MonoCtor
        { name = "Rect", tag = 0, fieldTypes = fieldTys }
        (fn fieldTys shapeTy)


fn : List Mono.MonoType -> Mono.MonoType -> Mono.MonoType
fn params ret =
    Mono.mFunction Mono.topLegacy params ret


{-| The site's callee type: the PAP's RESIDUAL, head-annotated with the
singleton `{p|add|k}` (Translate.injectPapMember injects at the residual HEAD).
-}
fn1 : List Mono.MonoType -> Mono.MonoType -> Mono.MonoType
fn1 params ret =
    Mono.mFunction (Mono.LSet [ pap ]) params ret


{-| A registry SPEC node of the global: a top-level, capture-free closure
with the given flat parameter row. No `lssMember`, so it is not an instance
in AbiCloning's closure index — it is reached only through `specsByGlobal`.
-}
specClosure : List Mono.MonoType -> Mono.MonoType -> Mono.MonoNode
specClosure paramTys ret =
    let
        params =
            List.indexedMap (\i t -> ( "p" ++ String.fromInt i, t )) paramTys

        -- The body's TYPE is the spec's return type: `specFunctionRow`
        -- derives the return from `Mono.typeOf body` exactly as
        -- `insertInstance` does, so a body typed as a parameter would make
        -- a `[Float, Int] -> Int` spec report `Float` and silently drop out
        -- of the match set (which is how pins 2 and 6 first passed for the
        -- wrong reason).
        body =
            Mono.MonoVarLocal "r" ret
    in
    Mono.MonoDefine
        (Mono.MonoClosure
            { lambdaId = Mono.AnonymousLambda home 1
            , srcLambda = Nothing
            , lssMember = Nothing
            , captures = []
            , params = params
            , closureKind = Nothing
            , captureAbi = Nothing
            }
            body
            (fn paramTys ret)
        )
        (fn paramTys ret)


{-| A site applying `argCount` args to a local var of the residual type. The
third argument is unused except to document k at the call site.
-}
papSite : Int -> Mono.MonoType -> Int -> Mono.MonoExpr
papSite argCount calleeTy _ =
    Mono.MonoCall A.zero
        (Mono.MonoVarLocal "h" calleeTy)
        (List.repeat argCount (Mono.MonoLiteral (Mono.LInt 1) Mono.MInt))
        (case calleeTy of
            Mono.MFunction _ _ _ r ->
                r

            other ->
                other
        )
        Mono.defaultCallInfo


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


firstCall : Mono.MonoGraph -> Maybe Mono.MonoExpr
firstCall (Mono.MonoGraph record) =
    case Array.get 0 record.nodes of
        Just (Just (Mono.MonoDefine (Mono.MonoList _ exprs _) _)) ->
            List.head
                (List.filter
                    (\e ->
                        case e of
                            Mono.MonoCall _ _ _ _ _ ->
                                True

                            _ ->
                                False
                    )
                    exprs
                )

        _ ->
            Nothing


firstCallInfo : Mono.MonoGraph -> Maybe Mono.CallInfo
firstCallInfo g =
    case firstCall g of
        Just (Mono.MonoCall _ _ _ _ ci) ->
            Just ci

        _ ->
            Nothing


calleeIsLocal : Mono.MonoGraph -> Bool
calleeIsLocal g =
    case firstCall g of
        Just (Mono.MonoCall _ (Mono.MonoVarLocal _ _) _ _ _) ->
            True

        _ ->
            False


{-| Node 0 holds the sites; nodes 1.. are the registry specs, at the SAME
index as their `reverseMapping` entry (nodes and reverseMapping share the
SpecId index). `postSettle` is on: `papFast` rides E9.5's indices.
-}
run : Bool -> Dict.Dict Int Mono.MemberOrigin -> Mono.SpecializationRegistry -> List Mono.MonoNode -> List Mono.MonoExpr -> ( Mono.MonoGraph, AbiCloning.AbiCloningStats )
run papFast memberOrigins registry specNodes exprs =
    AbiCloning.abiCloningPass True
        True
        True
        True
        papFast
        (Mono.MonoGraph
            { nodes =
                Array.fromList
                    (Just
                        (Mono.MonoDefine
                            (Mono.MonoList A.zero exprs (Mono.mList Mono.MInt))
                            (Mono.mList Mono.MInt)
                        )
                        :: List.map Just specNodes
                    )
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
