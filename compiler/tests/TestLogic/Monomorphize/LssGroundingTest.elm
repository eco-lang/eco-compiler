module TestLogic.Monomorphize.LssGroundingTest exposing (suite)

{-| Tests for grounding, the step of the solver engine that gives a global used
as a function value one lambda-set member per layout it is used at.

A lambda set is the annotation on a function type naming the function values
that can flow through it, its members, each numbered by an interned member id
(`Compiler.MonoSolver.Engine` owns the numbering). A slot is the member list of
one arrow's set. An arrow's layout is its type with the lambda-set annotations
in it disregarded, so two arrows that differ only in their sets share a layout.

A top-level global or constructor used as a function value, other than a global
that aliases a kernel function, is first given a provisional member, whose key
names only the global, recorded in the member table's `provisionalStandalone`.
When a set is read back at an arrow whose parameter and result types contain no
type variable, `Engine.groundSetMembers` replaces each provisional member with
a ground member keyed by the global and that arrow's layout, so one polymorphic
global used at two types becomes two members. At an arrow whose type still
holds a type variable it keeps the provisional id; this is called deferral.
The solver applies the set-size cap to the grounded list, so grounding must
never make a slot longer. These tests pin those rules directly, and count the
member entries the solver pipeline records for one polymorphic global.

The pure tests call `Engine.groundSetMembers` directly. Their member table
starts empty with the next id at 100, and `mintProvisional` registers
provisional members for the globals `fnA` and `fnB` of module `M`. The pipeline
test runs the solver engine on `twoLayoutModule`, in which one polymorphic
function is passed to an `Int -> Int` consumer and to a `Float -> Float` one.

What the tests establish:

  - Grounding one provisional member at `Int -> Int` gives exactly the next id
    from the supply, counts one grounded and none deferred, advances the supply
    by one, records the new id as `SourceGlobal fnA` and not as provisional, and
    drops the provisional id.
  - At an arrow whose parameter is a number type variable the member list is
    unchanged, one member is counted deferred, and no id or key is added.
  - Grounding the result of a grounding again at the same arrow returns the same
    members, counts nothing and leaves the supply where it was.
  - One provisional member grounded at `Int -> Int` and then at
    `Int -> (Int -> Int)` gives two different ids, both recorded as
    `SourceGlobal fnA`.
  - A slot holding a provisional member and its own ground member comes back as
    the ground member alone, with one grounded and no new id.
  - A slot holding the non-provisional id 7 and the provisional members of
    `fnA` and `fnB` comes back with three members, two grounded, 7 still
    present, in ascending order.
  - A slot with no provisional member is returned unchanged, with nothing
    counted and the supply unchanged.
  - The pipeline test requires at least three entries of the graph's
    `lssMemberOrigins` to name a global called `myId`. The threshold is meant
    as the provisional member plus one ground member per layout, but the test
    does not tell the entries apart.

Among what is not tested: constructor members, deferral when only the result
type holds a type variable, the set-size cap itself, whether the pipeline's
two ground members are distinct or appear in any annotation, and whether the
`myId` entries come from grounding a reference or from the fold of `myId`'s own
root lambda, which interns keys of the same shape.

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
import Compiler.Elm.ModuleName as ModuleName
import Compiler.MonoSolver.Engine as Engine
import Dict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The grounding tests: seven pure tests of `Engine.groundSetMembers` and one
pipeline test through the solver engine.
-}
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
                            -- A ground id is not provisional, so grounding it
                            -- again passes it through.
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

                        -- The inner and head arrows of an `Int -> Int -> Int` function.
                        rInner =
                            Engine.groundSetMembers Mono.MInt Mono.MInt [ midA ] t1 n1

                        rHead =
                            Engine.groundSetMembers Mono.MInt (Mono.mFunction Mono.topLegacy [ Mono.MInt ] Mono.MInt) [ midA ] rInner.table rInner.nextId
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

                        -- midA < gid, so this input is ascending, as a stored set is.
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
                            -- The cap is applied after grounding, so the count
                            -- must not grow.
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
        , Test.describe "pipeline (wiring end to end)"
            [ Test.test "one ground id per demanded layout, all SourceGlobal-resolvable" <|
                \() ->
                    case run of
                        Err msg ->
                            Expect.fail msg

                        Ok facts ->
                            -- Meant as the provisional id plus one ground id per
                            -- layout; the count does not tell them apart.
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


{-| The module `M` of package `author/pkg`, home of the fixture globals.
-}
homeM : ModuleName.Canonical
homeM =
    ModuleName.Canonical ( "author", "pkg" ) "M"


{-| The global `M.fnA`, whose provisional member most pure tests ground.
-}
gA : TOpt.Global
gA =
    TOpt.Global homeM "fnA"


{-| The global `M.fnB`, whose provisional member is the second one in the
no-growth test.
-}
gB : TOpt.Global
gB =
    TOpt.Global homeM "fnB"


{-| The starting member table and id supply: an empty table, with 100 as the
next id to mint.
-}
base : ( Engine.LssMemberTable, Int )
base =
    ( Engine.emptyMemberTable, 100 )


{-| Mints a provisional member for global `g` under `key`, returning its id and
the updated table and supply.

It makes the same table writes as `Engine.standaloneMemberIdFor`, which needs
the engine's full state: it interns `key`, records the id as `SourceGlobal g`,
and marks it provisional. Unlike that function, it writes both entries even
when the id already has a source, which that function leaves untouched.

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


{-| What the pipeline test reads from the monomorphized graph.

`myIdOrigins` counts the entries of `lssMemberOrigins` that resolve to a
global called `myId`, in whatever module.

-}
type alias Facts =
    { myIdOrigins : Int
    }


{-| The facts of `twoLayoutModule` after the solver engine has monomorphized
it with the default limits and lambda-set settings, or the pipeline's error.

Setting `enabled = True` changes nothing, because it is already the default.

-}
run : Result String Facts
run =
    let
        defaults =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithLimits
        Config.defaultLimits
        { defaults | enabled = True }
        twoLayoutModule
        |> Result.map factsOf


{-| Returns the facts of a monomorphized graph.
-}
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


{-| A module in which one polymorphic function, `myId : a -> a`, is used at two
layouts: passed to `applyI` at `Int -> Int` and to `applyF` at
`Float -> Float`, both from `testValue`.
-}
twoLayoutModule : Src.Module
twoLayoutModule =
    makeModuleWithTypedDefs "Test" [ myIdDef, applyIDef, applyFDef, testValueDef ]


{-| The identity function `myId : a -> a`.
-}
myIdDef : TypedDef
myIdDef =
    { name = "myId"
    , args = [ pVar "x" ]
    , tipe = tLambda (tVar "a") (tVar "a")
    , body = varExpr "x"
    }


{-| `applyI : (Int -> Int) -> Int`, which applies its argument to 1.
-}
applyIDef : TypedDef
applyIDef =
    { name = "applyI"
    , args = [ pVar "f" ]
    , tipe = tLambda (tLambda (tType "Int" []) (tType "Int" [])) (tType "Int" [])
    , body = callExpr (varExpr "f") [ intExpr 1 ]
    }


{-| `applyF : (Float -> Float) -> Float`, which applies its argument to 1.5.
-}
applyFDef : TypedDef
applyFDef =
    { name = "applyF"
    , args = [ pVar "f" ]
    , tipe = tLambda (tLambda (tType "Float" []) (tType "Float" [])) (tType "Float" [])
    , body = callExpr (varExpr "f") [ floatExpr 1.5 ]
    }


{-| `testValue : Int`, defined as `applyI myId + round (applyF myId)`, the
value the test pipeline's `main` refers to.
-}
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
