module TestLogic.Monomorphize.AbiCloningFlatPeelPassTest exposing (suite)

{-| FIX A at the PASS level — `lss.stamp.flatPeel`
(`plans/lss-instance-qualified-members.md` §15.1/§17.5 pins 6 and 7).

`AbiCloningFlatPeelTest` pins `peelStages` in isolation; these drive the whole
pass on hand-built graphs, in the `AbiCloningFenceTest` mould, because the
properties that matter are about which sites the pass STAMPS.

`Store.classifyGo` gives every arrow ONE parameter per `MFunction` stage, so a
callback of arity 3 has a callee type whose first stage is 1 while the closure
is a flat 3-parameter object and the call applies 3 arguments at once. Fix A
peels the type to the site's own arg count and matches the INSTANCE — the only
authority on representation — against that.

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
    Test.describe "Fix A at the pass level (lss.stamp.flatPeel)"
        [ Test.test "1. DIFFERENTIAL: an over-applying site declines flag-off and STAMPS flag-on" <|
            \() ->
                -- The plan's headline claim. A 3-parameter instance under a
                -- singleton member, consulted by a site whose callee type is
                -- curried (first stage = 1) and which applies 3 args flat.
                let
                    graph =
                        [ flatClosure 1 member [ Mono.MInt, Mono.MInt, Mono.MInt ] intBody
                        , overSite 3 Mono.MInt
                        ]
                in
                Expect.all
                    [ \_ -> Expect.equal 0 (statsWith False graph).dispatchUpgraded
                    , \_ -> Expect.equal 1 (statsWith False graph).declinedShapeArityOver
                    , \_ -> Expect.equal 1 (statsWith True graph).dispatchUpgraded
                    , \_ -> Expect.equal 0 (statsWith True graph).declinedShapeArityOver
                    ]
                    ()
        , Test.test "2. A PAP SUFFIX NEVER QUALIFIES — a 4-param instance is not stamped at a 3-arg site" <|
            \() ->
                -- Review B2, the soundness property. `resolvePapSuffix` exists
                -- because partially-applied values DO flow through these
                -- positions, and a 1-dropped suffix of [p,p,p,p] would match
                -- the site's flattened [Int,Int,Int]. Stamping that would
                -- direct-call a 4-parameter clone with 3 arguments.
                --
                -- Structurally the flattened path can never reach it: it does
                -- ONE bucket lookup keyed by the full flattened param list,
                -- where `resolvePapSuffix` scans across every bucket. This
                -- pins that structure against a future "simplification".
                let
                    graph =
                        [ flatClosure 1 member [ Mono.MInt, Mono.MInt, Mono.MInt, Mono.MInt ] intBody
                        , overSite 3 Mono.MInt
                        ]
                in
                Expect.all
                    [ \_ -> Expect.equal 0 (statsWith True graph).dispatchUpgraded
                    , \_ -> Expect.equal 1 (statsWith True graph).declinedShapeArityOver
                    ]
                    ()
        , Test.test "3. Fix A does NOT bypass the LSS_024 fence: divergent bodies still decline" <|
            \() ->
                -- Plan §15.0. Getting past the arity guard must land the site
                -- on the NEXT guard, not on a stamp — otherwise Fix A would
                -- have opened the representative-hijack hole the fence exists
                -- to close. This is why `declinedBodyMismatch` rose 78 -> 1,204
                -- on the self-compile: the population was always there, masked
                -- behind a check that fired first.
                let
                    graph =
                        [ flatClosure 1 member [ Mono.MInt, Mono.MInt, Mono.MInt ] (annoBody 777)
                        , flatClosure 2 member [ Mono.MInt, Mono.MInt, Mono.MInt ] (annoBody 778)
                        , overSite 3 (annoRet 777)
                        ]
                in
                Expect.all
                    [ \_ -> Expect.equal 0 (statsWith True graph).dispatchUpgraded
                    , \_ -> Expect.equal 1 (statsWith True graph).declinedBodyMismatch
                    , \_ -> Expect.equal 0 (statsWith True graph).declinedShapeArityOver
                    ]
                    ()
        , Test.test "4. an EXACTLY-saturating site is untouched by the flag" <|
            \() ->
                -- Fix A must only ever fire on the over-applying branch.
                let
                    graph =
                        [ flatClosure 1 member [ Mono.MInt ] intBody
                        , exactSite
                        ]
                in
                Expect.equal (statsWith False graph).dispatchUpgraded (statsWith True graph).dispatchUpgraded
        ]



-- ====== FIXTURE MACHINERY ======


member : Int
member =
    99991


home : IO.Canonical
home =
    IO.Canonical ( "author", "proj" ) "M"


intBody : Mono.MonoExpr
intBody =
    Mono.MonoVarLocal "p0" Mono.MInt


{-| Layout-identical to `intBody`'s sibling but ANNOTATION-divergent, so the
two land in one bucket and one layout group while their fingerprints differ.
-}
annoBody : Int -> Mono.MonoExpr
annoBody mid =
    Mono.MonoVarLocal "k" (annoRet mid)


annoRet : Int -> Mono.MonoType
annoRet mid =
    Mono.mFunction (Mono.LSet [ mid ]) [ Mono.MInt ] Mono.MInt


{-| A FLAT n-parameter closure instance — what mono-uncurry actually produces,
and what the curried callee type at the call site fails to describe.
-}
flatClosure : Int -> Int -> List Mono.MonoType -> Mono.MonoExpr -> Mono.MonoExpr
flatClosure uid mid paramTys body =
    Mono.MonoClosure
        { lambdaId = Mono.AnonymousLambda home uid
        , srcLambda = Nothing
        , lssMember = Just mid
        , captures = []
        , params = List.indexedMap (\i t -> ( "p" ++ String.fromInt i, t )) paramTys
        , closureKind = Nothing
        , captureAbi = Nothing
        }
        body
        (Mono.mFunction (Mono.LSet [ mid ]) paramTys (Mono.typeOf body))


{-| The shape `Store.classifyGo` produces: one parameter per stage.
-}
curried : Mono.LambdaSetAnno -> Int -> Mono.MonoType -> Mono.MonoType
curried headAnno n ret =
    List.foldr
        (\i acc ->
            Mono.mFunction
                (if i == 0 then
                    headAnno

                 else
                    Mono.topLegacy
                )
                [ Mono.MInt ]
                acc
        )
        ret
        (List.range 0 (n - 1))


{-| An OVER-APPLYING site: curried callee type (first stage = 1), `n` args flat.
-}
overSite : Int -> Mono.MonoType -> Mono.MonoExpr
overSite n ret =
    Mono.MonoCall A.zero
        (Mono.MonoVarLocal "h" (curried (Mono.LSet [ member ]) n ret))
        (List.map (\i -> Mono.MonoLiteral (Mono.LInt i) Mono.MInt) (List.range 1 n))
        ret
        Mono.defaultCallInfo


exactSite : Mono.MonoExpr
exactSite =
    Mono.MonoCall A.zero
        (Mono.MonoVarLocal "h" (Mono.mFunction (Mono.LSet [ member ]) [ Mono.MInt ] Mono.MInt))
        [ Mono.MonoLiteral (Mono.LInt 1) Mono.MInt ]
        Mono.MInt
        Mono.defaultCallInfo


statsWith : Bool -> List Mono.MonoExpr -> AbiCloning.AbiCloningStats
statsWith flatPeel exprs =
    Tuple.second
        (AbiCloning.abiCloningPass True
            False
            flatPeel
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
                , lssMemberKinds = Dict.empty
                , lssBlockedMembers = Dict.empty
                }
            )
        )
