module TestLogic.Monomorphize.LssGroundingTest exposing (suite)

{-| LSS_019 — standalone-member grounding (GAP-1,
`plans/lss-fidelity-2-standalone-member-grounding.md`).

Two layers:

1.  PURE tests against `Engine.groundSetMembers` — the zonk-time rewrite
    itself: provisional→ground at a concrete arrow, deferral at a residual
    arrow, idempotence (ground ids pass through untouched — the LSS_010
    stability property), per-arrow-layout distinctness (the LSS_013 spine
    reading: a PAP stage's identity is (global × stage layout)), dedup of
    {provisional, its-own-ground}, and the no-growth property that makes
    rewrite-before-cap safe (plan §3.2 detail 3).
2.  PIPELINE tests through the real solver — the flag wiring end to end: a
    polymorphic global flowing at TWO layouts into two HOFs mints, flag-on,
    one GROUND member per layout (observable in `MonoGraph.lssMemberOrigins`
    via the `g|<global>|<typeKey>` interns, each `SourceGlobal`-resolvable
    through `buildMemberOrigins` with zero consumer changes), while flag-off
    keeps exactly today's one family id.

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , callExpr
        , floatExpr
        , intExpr
        , makeModuleWithTypedDefs
        , pVar
        , tLambda
        , tType
        , tVar
        , varExpr
        )
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Eco.Config as Config
import Compiler.MonoSolver.Engine as Engine
import Dict
import Expect
import System.TypeCheck.IO as IO
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "LSS_019 standalone-member grounding"
        [ Test.describe "groundSetMembers (pure rewrite)"
            [ Test.test "provisional grounds at a concrete arrow (fresh id, SourceGlobal-resolvable, not provisional)" <|
                \() ->
                    let
                        ( midA, ( t1, n1 ) ) =
                            mintProvisional "g|author/pkg.M.fnA" gA base

                        r =
                            Engine.groundSetMembers Mono.MInt Mono.MInt [ midA ] t1 n1
                    in
                    Expect.all
                        [ \_ -> Expect.equal [ n1 ] r.members
                        , \_ -> Expect.equal ( 1, 0 ) ( r.grounded, r.deferred )
                        , \_ -> Expect.equal (n1 + 1) r.nextId
                        , \_ -> Expect.equal (Just (Engine.SourceGlobal gA)) (Dict.get n1 r.table.sources)
                        , \_ ->
                            -- Ground ids are NEVER provisional — that is what
                            -- makes grounding idempotent.
                            Expect.equal Nothing (Dict.get n1 r.table.provisionalStandalone)
                        , \_ ->
                            if List.member midA r.members then
                                Expect.fail "provisional id survived a concrete-arrow rewrite"

                            else
                                Expect.pass
                        ]
                        ()
            , Test.test "deferral at a residual-carrying arrow keeps the provisional id" <|
                \() ->
                    let
                        ( midA, ( t1, n1 ) ) =
                            mintProvisional "g|author/pkg.M.fnA" gA base

                        residual =
                            Mono.MVar TypeIds.firstMVarId Mono.CNumber

                        r =
                            Engine.groundSetMembers residual Mono.MInt [ midA ] t1 n1
                    in
                    Expect.all
                        [ \_ -> Expect.equal [ midA ] r.members
                        , \_ -> Expect.equal ( 0, 1 ) ( r.grounded, r.deferred )
                        , \_ -> Expect.equal n1 r.nextId
                        , \_ -> Expect.equal (Dict.size t1.byKey) (Dict.size r.table.byKey)
                        ]
                        ()
            , Test.test "idempotence: re-grounding a ground set is the identity (no interns, no census)" <|
                \() ->
                    let
                        ( midA, ( t1, n1 ) ) =
                            mintProvisional "g|author/pkg.M.fnA" gA base

                        r1 =
                            Engine.groundSetMembers Mono.MInt Mono.MInt [ midA ] t1 n1

                        r2 =
                            Engine.groundSetMembers Mono.MInt Mono.MInt r1.members r1.table r1.nextId
                    in
                    Expect.all
                        [ \_ -> Expect.equal r1.members r2.members
                        , \_ -> Expect.equal ( 0, 0 ) ( r2.grounded, r2.deferred )
                        , \_ -> Expect.equal r1.nextId r2.nextId
                        ]
                        ()
            , Test.test "spine: head and inner arrows of a 2-ary global get DISTINCT ground ids, both resolvable" <|
                \() ->
                    let
                        ( midA, ( t1, n1 ) ) =
                            mintProvisional "g|author/pkg.M.fnA" gA base

                        -- add : Int -> Int -> Int. Inner (depth-2) arrow:
                        -- Int -> Int; head arrow: Int -> (Int -> Int).
                        rInner =
                            Engine.groundSetMembers Mono.MInt Mono.MInt [ midA ] t1 n1

                        rHead =
                            Engine.groundSetMembers Mono.MInt (Mono.mFunction Mono.LTop [ Mono.MInt ] Mono.MInt) [ midA ] rInner.table rInner.nextId
                    in
                    case ( rInner.members, rHead.members ) of
                        ( [ idInner ], [ idHead ] ) ->
                            Expect.all
                                [ \_ ->
                                    if idInner == idHead then
                                        Expect.fail "head and inner arrow layouts must ground to DISTINCT ids (PAP-stage identity is (global × stage layout))"

                                    else
                                        Expect.pass
                                , \_ -> Expect.equal (Just (Engine.SourceGlobal gA)) (Dict.get idInner rHead.table.sources)
                                , \_ -> Expect.equal (Just (Engine.SourceGlobal gA)) (Dict.get idHead rHead.table.sources)
                                ]
                                ()

                        _ ->
                            Expect.fail "expected singleton rewrites at both arrows"
            , Test.test "dedup: {provisional, its-own-ground} in one slot collapses after the rewrite" <|
                \() ->
                    let
                        ( midA, ( t1, n1 ) ) =
                            mintProvisional "g|author/pkg.M.fnA" gA base

                        r1 =
                            Engine.groundSetMembers Mono.MInt Mono.MInt [ midA ] t1 n1

                        gid =
                            case r1.members of
                                [ m ] ->
                                    m

                                _ ->
                                    -1

                        -- midA < gid (fresh ids come from a later supply), so
                        -- the input list is ascending as LSS_001 requires.
                        r2 =
                            Engine.groundSetMembers Mono.MInt Mono.MInt [ midA, gid ] r1.table r1.nextId
                    in
                    Expect.all
                        [ \_ -> Expect.equal [ gid ] r2.members
                        , \_ -> Expect.equal 1 r2.grounded
                        , \_ -> Expect.equal r1.nextId r2.nextId
                        ]
                        ()
            , Test.test "no growth: distinct globals stay distinct; non-provisional members pass through (cap ordering premise)" <|
                \() ->
                    let
                        ( midA, st1 ) =
                            mintProvisional "g|author/pkg.M.fnA" gA base

                        ( midB, ( t2, n2 ) ) =
                            mintProvisional "g|author/pkg.M.fnB" gB st1

                        lambdaId =
                            7

                        r =
                            Engine.groundSetMembers Mono.MInt Mono.MInt [ lambdaId, midA, midB ] t2 n2
                    in
                    Expect.all
                        [ \_ ->
                            -- Per-slot size never grows from grounding alone
                            -- (§3.2 detail 3: rewrite-then-cap never regresses
                            -- the cap semantics).
                            Expect.equal 3 (List.length r.members)
                        , \_ -> Expect.equal 2 r.grounded
                        , \_ ->
                            if List.member lambdaId r.members then
                                Expect.pass

                            else
                                Expect.fail "non-provisional (lambda) member must pass through untouched"
                        , \_ -> Expect.equal (List.sort r.members) r.members
                        ]
                        ()
            , Test.test "fast path: a slot with no provisional members is returned unchanged" <|
                \() ->
                    let
                        r =
                            Engine.groundSetMembers Mono.MInt Mono.MInt [ 1, 2, 3 ] Engine.emptyMemberTable 100
                    in
                    Expect.all
                        [ \_ -> Expect.equal [ 1, 2, 3 ] r.members
                        , \_ -> Expect.equal ( 0, 0 ) ( r.grounded, r.deferred )
                        , \_ -> Expect.equal 100 r.nextId
                        ]
                        ()
            ]
        , Test.describe "pipeline (flag wiring end to end)"
            [ Test.test "flag OFF: one family id per standalone global (today's semantics)" <|
                \() ->
                    case run False of
                        Err msg ->
                            Expect.fail msg

                        Ok facts ->
                            Expect.equal 1 facts.myIdOrigins
            , Test.test "flag ON: one ground id per demanded layout, all SourceGlobal-resolvable" <|
                \() ->
                    case run True of
                        Err msg ->
                            Expect.fail msg

                        Ok facts ->
                            -- myId flows at TWO layouts (Int -> Int and
                            -- Float -> Float): the provisional family id plus
                            -- one ground id per layout = 3 interned ids, every
                            -- one resolving to myId through the UNCHANGED
                            -- buildMemberOrigins prefix dispatch.
                            if facts.myIdOrigins >= 3 then
                                Expect.pass

                            else
                                Expect.fail
                                    ("expected ≥3 member ids resolving to myId (provisional + one ground per layout), got "
                                        ++ String.fromInt facts.myIdOrigins
                                    )
            ]
        ]



-- ====== PURE FIXTURES ======


homeM : IO.Canonical
homeM =
    IO.Canonical ( "author", "pkg" ) "M"


gA : TOpt.Global
gA =
    TOpt.Global homeM "fnA"


gB : TOpt.Global
gB =
    TOpt.Global homeM "fnB"


base : ( Engine.LssMemberTable, Int )
base =
    ( Engine.emptyMemberTable, 100 )


{-| Test mirror of `Engine.standaloneMemberIdFor`'s table writes (that
function is `Step`-shaped; the pure rewrite is what is under test here):
intern the key, record `SourceGlobal` and the PROVISIONAL marker.
-}
mintProvisional : String -> TOpt.Global -> ( Engine.LssMemberTable, Int ) -> ( Int, ( Engine.LssMemberTable, Int ) )
mintProvisional key g ( table0, next0 ) =
    let
        ( mid, table1, next1 ) =
            Engine.internMemberKey key table0 next0

        table2 =
            { table1
                | sources = Dict.insert mid (Engine.SourceGlobal g) table1.sources
                , provisionalStandalone = Dict.insert mid g table1.provisionalStandalone
            }
    in
    ( mid, ( table2, next1 ) )



-- ====== PIPELINE HARNESS ======


type alias Facts =
    { myIdOrigins : Int
    }


run : Bool -> Result String Facts
run ground =
    let
        defaults =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithLimits
        Config.defaultLimits
        { defaults | enabled = True, keyed = True, groundStandalones = ground }
        twoLayoutModule
        |> Result.map factsOf


factsOf : Mono.MonoGraph -> Facts
factsOf (Mono.MonoGraph g) =
    { myIdOrigins =
        Dict.foldl
            (\_ origin n ->
                case origin of
                    Mono.OriginGlobal (Mono.Global _ name) ->
                        if name == "myId" then
                            n + 1

                        else
                            n

                    _ ->
                        n
            )
            0
            g.lssMemberOrigins
    }



-- ====== FIXTURE ======


{-| ONE polymorphic global (`myId : a -> a`) flowing at TWO layouts
(`Int -> Int`, `Float -> Float`) into two HOFs. Flag-off both flows carry
the single family id `g|myId`; flag-on each HOF's param arrow zonk grounds
it against that arrow's own layout — two DISTINCT ground ids.
-}
twoLayoutModule : Src.Module
twoLayoutModule =
    makeModuleWithTypedDefs "Test" [ myIdDef, applyIDef, applyFDef, testValueDef ]


myIdDef : TypedDef
myIdDef =
    { name = "myId"
    , args = [ pVar "x" ]
    , tipe = tLambda (tVar "a") (tVar "a")
    , body = varExpr "x"
    }


applyIDef : TypedDef
applyIDef =
    { name = "applyI"
    , args = [ pVar "f" ]
    , tipe = tLambda (tLambda (tType "Int" []) (tType "Int" [])) (tType "Int" [])
    , body = callExpr (varExpr "f") [ intExpr 1 ]
    }


applyFDef : TypedDef
applyFDef =
    { name = "applyF"
    , args = [ pVar "f" ]
    , tipe = tLambda (tLambda (tType "Float" []) (tType "Float" [])) (tType "Float" [])
    , body = callExpr (varExpr "f") [ floatExpr 1.5 ]
    }


testValueDef : TypedDef
testValueDef =
    { name = "testValue"
    , args = []
    , tipe = tType "Int" []
    , body =
        binopsExpr
            [ ( callExpr (varExpr "applyI") [ varExpr "myId" ], "+" ) ]
            (callExpr (varExpr "round") [ callExpr (varExpr "applyF") [ varExpr "myId" ] ])
    }
