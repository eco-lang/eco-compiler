module TestLogic.Monomorphize.LssHonestSourcesTest exposing (suite)

{-| LSS_026(a) — honest ∅-as-source, demand side
(`plans/lss-gap2-callarg-transport.md` §3.2(a), Phase 1).

`Store.resolveSources` reads a terminal `FlexVar` SOURCE as an ∅
contribution. That is exact ONLY under write-completeness of every inflow to
the source slot — and A.1's disconnected instantiation params are precisely a
write-INCOMPLETE population, so a members-carrying resolution reached OVER a
dangling FlexVar claims a completeness it does not have (`Mono.LSet` IS a
completeness claim). LSS_026(a) widens exactly that case to ⊤.

These tests own the RESOLVER semantics of that rule, at the store level, on a
hand-built store — the `LssDirectedFlowTest` precedent (which owns the
pre-LSS_026 half: cycles, SCC exactness, ⊤ short-circuit, diamond dedupe).
`resolveSlotMembers` reads only `store`, `lss` and `memberTable` from its
`ZonkCtx`, so the fixture builds the record directly and toggles
`lss.honestSources` — the field `zonkToMono` seeds True in every production
zonk (`ZonkCtx` has no `S`, hence a field rather than a direct read); only
these pins ever seed it False, to assert the shape the rule exists to
reject.

The four cases are the plan's §5 Phase-1 list:

1.  members + a dangling-flex source → honest-ON resolves `Nothing` (⊤),
    honest-OFF resolves the members (the RED/GREEN pair — OFF is what HEAD
    does, and it is the false-COMPLETE set).
2.  members = [] + a dangling flex → `Just []` in BOTH arms: the
    empty-resolution arm already reads `LTop` at `zonkSetSlot`, so nothing is
    claimed and nothing is widened (and no counter bumps).
3.  members + a WRITTEN source → the exact union, in both arms: no flex was
    crossed, so the rule is silent.
4.  the ⊤ short-circuit and the cycle walk still win under honest-ON —
    absorption is checked BEFORE the mixed test, and a cycle whose SCC is
    fully written is not mixed.

Plus the census riders, which are FLAG-INDEPENDENT by design (§2.1b): the
`mixedFlex` counter must bump in both arms, and `mixedFlexGc` only when the
carried members include a standalone global/ctor — the escalation class,
since a `gc` member grounds (LSS_019) and is devirt-consumable (LSS_025),
where a raw lambda id merely declines (LSS_017).

-}

import Compiler.AST.Intern as Intern
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.MonoSolver.Engine as Engine
import Compiler.MonoSolver.Store as Store
import Compiler.Type.Type as Type
import Compiler.Type.UnionFind as UF
import Dict
import Expect
import System.TypeCheck.IO as IO
import Test exposing (Test)


suite : Test
suite =
    Test.describe "LSS_026(a) honest ∅-as-source (demand resolver, store level)"
        [ Test.test "1a. members + a DANGLING flex source: honest-ON widens to ⊤" <|
            \() ->
                Expect.equal Nothing (.members (mixedFixture True))
        , Test.test "1b. the same store, honest-OFF: HEAD publishes the false-COMPLETE set" <|
            \() ->
                -- The RED half. This is not an aspiration — it asserts the
                -- hole EXISTS at HEAD, so the record stays honest if someone
                -- deletes the rule instead of the leak.
                Expect.equal (Just [ 4 ]) (.members (mixedFixture False))
        , Test.test "1c. the crossing is CENSUSED in both arms (counters are flag-independent)" <|
            \() ->
                Expect.equal ( 1, 1 ) ( .mixed (mixedFixture True), .mixed (mixedFixture False) )
        , Test.test "2a. members = [] + a dangling flex: Just [] in BOTH arms (already ⊤ at readback)" <|
            \() ->
                Expect.equal ( Just [], Just [] )
                    ( .members (emptyFixture True), .members (emptyFixture False) )
        , Test.test "2b. …and it is NOT counted as mixed (nothing was claimed)" <|
            \() ->
                Expect.equal ( 0, 0 ) ( .mixed (emptyFixture True), .mixed (emptyFixture False) )
        , Test.test "3a. members + a WRITTEN source: the exact union, unchanged by the rule" <|
            \() ->
                Expect.equal ( Just [ 4, 9 ], Just [ 4, 9 ] )
                    ( .members (writtenFixture True), .members (writtenFixture False) )
        , Test.test "3b. …and no crossing is counted" <|
            \() ->
                Expect.equal ( 0, 0 ) ( .mixed (writtenFixture True), .mixed (writtenFixture False) )
        , Test.test "4a. a reachable ⊤ still absorbs under honest-ON (absorption is tested first)" <|
            \() ->
                Expect.equal ( Nothing, 0 ) ( .members (topFixture True), .mixed (topFixture True) )
        , Test.test "4b. a fully-written 2-cycle terminates and is NOT mixed under honest-ON" <|
            \() ->
                Expect.equal ( Just [ 1, 2 ], 0 ) ( .members (cycleFixture True), .mixed (cycleFixture True) )
        , Test.test "4c. a cycle that reaches a dangling flex IS mixed → ⊤ under honest-ON" <|
            \() ->
                Expect.equal ( Nothing, 1 ) ( .members (cycleFlexFixture True), .mixed (cycleFlexFixture True) )
        , Test.test "5a. the escalation class: a `gc` member in a mixed set bumps mixedFlexGc" <|
            \() ->
                -- A standalone-global member GROUNDS at the consuming zonk
                -- (LSS_019) and IS consumable by LSS_025 post-settle devirt,
                -- so a false `{g|X}` singleton is the representative-hijack
                -- MISCOMPILE class — which is why the plan's Phase-0 gate
                -- keys on this counter and not on `mixedFlex`.
                Expect.equal ( 1, 1 ) ( .mixed (gcFixture True), .mixedGc (gcFixture True) )
        , Test.test "5b. a lambda-id member in a mixed set does NOT bump mixedFlexGc" <|
            \() ->
                Expect.equal ( 1, 0 ) ( .mixed (mixedFixture True), .mixedGc (mixedFixture True) )
        ]



-- ====== FIXTURES ======


{-| members `[4]` reached over ONE terminal FlexVar source: the §0.5 shape.
-}
mixedFixture : Bool -> Outcome
mixedFixture honest =
    runResolve honest Engine.emptyMemberTable [ 4 ] <|
        \_ -> mintOne (IO.FlexVar Nothing)


{-| No members anywhere, one dangling flex: the empty-resolution arm.
-}
emptyFixture : Bool -> Outcome
emptyFixture honest =
    runResolve honest Engine.emptyMemberTable [] <|
        \_ -> mintOne (IO.FlexVar Nothing)


{-| members `[4]` plus a source that is WRITTEN (`{9}`): no crossing.
-}
writtenFixture : Bool -> Outcome
writtenFixture honest =
    runResolve honest Engine.emptyMemberTable [ 4 ] <|
        \_ -> mintOne (IO.Structure (IO.LambdaSet1 (IO.LsMembers [ 9 ])))


{-| members `[4]` plus a reachable ⊤ — absorption must win over the mixed
rule (⊤ is the same answer, but by the SHORT-CIRCUIT path, so no crossing is
recorded).
-}
topFixture : Bool -> Outcome
topFixture honest =
    runResolve honest Engine.emptyMemberTable [ 4 ] <|
        \_ -> mintOne (IO.Structure (IO.LambdaSet1 IO.LsTop))


{-| A ⊇ B, B ⊇ A, both carrying members and NO flex: the LssDirectedFlowTest
cycle, re-asserted under the new signature.
-}
cycleFixture : Bool -> Outcome
cycleFixture honest =
    runResolve honest Engine.emptyMemberTable [ 1 ] <|
        \_ ->
            UF.fresh (desc (IO.FlexVar Nothing))
                |> IO.andThen
                    (\b ->
                        UF.fresh (desc (lsFrom [ 2 ] [ b ]))
                            |> IO.andThen
                                (\a ->
                                    UF.set b (desc (lsFrom [] [ a ]))
                                        |> IO.map (\_ -> [ a ])
                                )
                    )


{-| The same cycle, but one SCC node ALSO points at a dangling flex — the
crossing must survive the visited-set walk.
-}
cycleFlexFixture : Bool -> Outcome
cycleFlexFixture honest =
    runResolve honest Engine.emptyMemberTable [ 1 ] <|
        \_ ->
            UF.fresh (desc (IO.FlexVar Nothing))
                |> IO.andThen
                    (\dangling ->
                        UF.fresh (desc (IO.FlexVar Nothing))
                            |> IO.andThen
                                (\b ->
                                    UF.fresh (desc (lsFrom [ 2 ] [ b ]))
                                        |> IO.andThen
                                            (\a ->
                                                UF.set b (desc (lsFrom [] [ a, dangling ]))
                                                    |> IO.map (\_ -> [ a ])
                                            )
                                )
                    )


{-| A mixed set whose member is a STANDALONE GLOBAL (member id 4 registered
as `SourceGlobal`) — the escalation class.
-}
gcFixture : Bool -> Outcome
gcFixture honest =
    runResolve honest gcMemberTable [ 4 ] <|
        \_ -> mintOne (IO.FlexVar Nothing)


gcMemberTable : Engine.LssMemberTable
gcMemberTable =
    let
        t =
            Engine.emptyMemberTable
    in
    { t
        | sources =
            Dict.insert 4
                (Engine.SourceGlobal (TOpt.Global (IO.Canonical ( "author", "project" ) "Test") "target"))
                t.sources
    }



-- ====== HARNESS ======


{-| What one resolution reports: the resolved member list (`Nothing` = ⊤) and
the two census counters the walk folded into the zonk accumulator.
-}
type alias Outcome =
    { members : Maybe (List Int)
    , mixed : Int
    , mixedGc : Int
    }


{-| Build a store with `mkSources`, then resolve `members0` over the sources it
returns, with `honestSources` set to `honest`.
-}
runResolve : Bool -> Engine.LssMemberTable -> List Int -> (() -> IO.IO (List IO.Variable)) -> Outcome
runResolve honest table members0 mkSources =
    IO.unsafePerformIO
        (mkSources ()
            |> IO.andThen
                (\srcs ->
                    captureState
                        |> IO.map
                            (\st ->
                                let
                                    ( res, c ) =
                                        Store.resolveSlotMembers members0 srcs (ctx honest table st)
                                in
                                { members = res
                                , mixed = counter .mixedFlex c
                                , mixedGc = counter .mixedFlexGc c
                                }
                            )
                )
        )


mintOne : IO.Content -> IO.IO (List IO.Variable)
mintOne content =
    UF.fresh (desc content) |> IO.map (\v -> [ v ])


desc : IO.Content -> IO.Descriptor
desc content =
    IO.makeDescriptor content Type.noRank Type.noMark Nothing


lsFrom : List Int -> List IO.Variable -> IO.Content
lsFrom members sources =
    IO.Structure (IO.LambdaSet1 (IO.LsFrom members sources))


captureState : IO.IO IO.State
captureState =
    \st -> ( st, st )


{-| The `ZonkCtx` `resolveSlotMembers` reads: `store` for the walk, `lss` for
the policy bit + counters, `memberTable` for the `gc` classification. The rest
are inert placeholders (the `LssDirectedFlowTest` precedent).

`censusOn` is True so the counters are live — they are FLAG-INDEPENDENT
(§2.1b: the policy that widens is gated, the counters are not), which is what
tests 1c/2b/3b assert.

-}
ctx : Bool -> Engine.LssMemberTable -> IO.State -> ZonkCtxShape
ctx honest table st =
    { store = st
    , next = TypeIds.firstMVarId
    , lss =
        Just
            { maxSetSize = 8
            , zonked = 0
            , widenedBySize = 0
            , hist = Dict.empty
            , widenedHist = Dict.empty
            , groundStandalones = False
            , grounded = 0
            , groundingDeferred = 0
            , honestSources = honest
            , mixedFlex = 0
            , mixedFlexGc = 0
            , censusOn = True
            , causeSet = 0
            , causePoison = 0
            , causeFlex = 0
            , causeEdgeSet = 0
            , causeEdgeEmpty = 0
            , causeEdgeTop = 0
            , causeUnknown = 0
            , multiSets = Dict.empty

            -- LSS_035 (plans/lss-post-mono-architecture.md §3.2): the
            -- arrow-attribution tables. Empty here — this fixture drives
            -- `resolveSlotMembers` directly with `arrowOf = Dict.empty`, so
            -- nothing can attribute, which is exactly what this test wants.
            , varArrows = Dict.empty
            , setArrows = Dict.empty
            }
    , ecoReads = []
    , intern = Intern.empty
    , memberTable = table
    , nextMemberId = 0
    , arrowOf = Dict.empty
    , varOf = Dict.empty
    , nextVar = 0
    }


{-| `Store.ZonkCtx` is not exported by name; Elm's structural record aliases
make the shape enough. Kept as a local alias so the fixture reads once.
-}
type alias ZonkCtxShape =
    { store : IO.State
    , next : TypeIds.MVarId
    , lss : Maybe LssAccShape
    , ecoReads : List IO.Variable
    , intern : Intern.Intern
    , memberTable : Engine.LssMemberTable
    , nextMemberId : Int
    , arrowOf : Dict.Dict Int Int
    , varOf : Dict.Dict Int Int
    , nextVar : Int
    }


type alias LssAccShape =
    { maxSetSize : Int
    , zonked : Int
    , widenedBySize : Int
    , hist : Dict.Dict Int Int
    , widenedHist : Dict.Dict Int Int
    , groundStandalones : Bool
    , grounded : Int
    , groundingDeferred : Int
    , honestSources : Bool
    , mixedFlex : Int
    , mixedFlexGc : Int
    , censusOn : Bool
    , causeSet : Int
    , causePoison : Int
    , causeFlex : Int
    , causeEdgeSet : Int
    , causeEdgeEmpty : Int
    , causeEdgeTop : Int
    , causeUnknown : Int
    , multiSets : Dict.Dict Int (List Int)
    , varArrows : Dict.Dict Int Int
    , setArrows : Dict.Dict Int Int
    }


counter : (LssAccShape -> Int) -> ZonkCtxShape -> Int
counter get c =
    case c.lss of
        Just acc ->
            get acc

        Nothing ->
            -1
