module TestLogic.Monomorphize.LssHonestSourcesTest exposing (suite)

{-| A lambda-set resolution that carries members but passes through a source
nothing has written would read back as a complete set when it is not. These
tests pin the honest-sources rule of `Compiler.MonoSolver.Store`, which widens
such a resolution to top, and the counters that record it.

A lambda-set slot lists, as integer member ids, the functions that may reach
an arrow. A slot may also draw on other slots, its _sources_, and resolving it
collects the members of every slot reachable through sources. A set is a claim
that nothing else arrives. A source that still holds an unwritten `FlexVar`
contributes no members, which is exact only if nothing is ever written to it.
`Store.resolveSlotMembersWith` owns the rule: its first argument switches it
on, and it returns `Nothing` for top (any function may arrive) or `Just` the
ascending union of the members. A _mixed crossing_ is a resolution that
reaches an unwritten source, reaches no top, and collects at least one member.
With the rule on it gives top; with it off, the members found. Either way, when
the context holds a zonk accumulator, the store adds one to its `mixedFlex`,
and one to `mixedFlexGc` as well when a member is registered as a standalone
global (`Engine.SourceGlobal`, the `gc` class of `Engine.membersClass`). That
class has its own counter because, as `Engine.memberClassOf` describes, a
false set of globals can be turned into a direct call to the wrong function, a
miscompile, where a false set of lambdas only loses precision.

The fixtures build a small union-find store by hand, a few points holding
`FlexVar`, member, top or source-carrying lambda-set content, and call
`resolveSlotMembersWith` directly with the rule on, and for tests 1 to 3 also
with it off. The context record is built field by field, with a zonk accumulator
present so that the counters count.

What the tests establish:

  - 1a, 1b: members `[4]` over one unwritten source resolve to `Nothing` with
    the rule on and to `Just [4]` with it off.
  - 1c: that resolution is counted once in `mixedFlex` in both arms.
  - 2a, 2b: no members over one unwritten source resolve to `Just []` in both
    arms, and `mixedFlex` stays 0. The store reads an empty resolution back as
    unknown rather than as a set, so it claims nothing.
  - 3a, 3b: members `[4]` over a source holding the set `[9]` resolve to
    `Just [4, 9]` in both arms, and `mixedFlex` stays 0.
  - 4a: members `[4]` over a source that is top resolve to `Nothing` with the
    rule on, and `mixedFlex` stays 0, because top ends the walk before the
    mixed test is made.
  - 4b: two sources that name each other, both written, resolve to
    `Just [1, 2]` with the rule on, and `mixedFlex` stays 0.
  - 4c: the same cycle with one node also naming an unwritten source resolves
    to `Nothing` with the rule on, and `mixedFlex` is 1.
  - 5a: members `[4]`, with 4 registered as a standalone global, over one
    unwritten source give 1 in both `mixedFlex` and `mixedFlexGc` with the rule
    on.
  - 5b: the 1a resolution, whose member 4 is not in the member table, gives 1
    in `mixedFlex` and 0 in `mixedFlexGc`.

Among what is not tested: tests 4a to 5b with the rule off; kernel and
partial-application members; `Store.resolveSlotMembers`, which chooses the rule
from the context's `lssOn`; resolution with no accumulator, when nothing is
counted; and how a zonk reads a resolution back.

-}

import Compiler.AST.Intern as Intern
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Elm.ModuleName as ModuleName
import Compiler.MonoSolver.Engine as Engine
import Compiler.MonoSolver.Store as Store
import Compiler.Type.Type as Type
import Compiler.Type.UnionFind as UF
import Compiler.Type.Vars as Vars
import Dict
import Expect
import System.TypeCheck.IO as IO
import Test exposing (Test)


{-| The honest-sources tests, numbered as in the module docstring.
-}
suite : Test
suite =
    Test.describe "LSS_026(a) honest ∅-as-source (demand resolver, store level)"
        [ Test.test "1a. members + a DANGLING flex source: honest-ON widens to ⊤" <|
            \() ->
                Expect.equal Nothing (.members (mixedFixture True))
        , Test.test "1b. the same store, honest-OFF: HEAD publishes the false-COMPLETE set" <|
            \() ->
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
                Expect.equal ( 1, 1 ) ( .mixed (gcFixture True), .mixedGc (gcFixture True) )
        , Test.test "5b. a lambda-id member in a mixed set does NOT bump mixedFlexGc" <|
            \() ->
                Expect.equal ( 1, 0 ) ( .mixed (mixedFixture True), .mixedGc (mixedFixture True) )
        ]



-- ====== FIXTURES ======


{-| Resolves members `[4]` over one unwritten source, with the rule on when
`honest` is True.
-}
mixedFixture : Bool -> Outcome
mixedFixture honest =
    runResolve honest Engine.emptyMemberTable [ 4 ] <|
        \_ -> mintOne (Vars.FlexVar Nothing)


{-| Resolves no members over one unwritten source, with the rule on when
`honest` is True.
-}
emptyFixture : Bool -> Outcome
emptyFixture honest =
    runResolve honest Engine.emptyMemberTable [] <|
        \_ -> mintOne (Vars.FlexVar Nothing)


{-| Resolves members `[4]` over one source holding the set `[9]`, with the rule
on when `honest` is True.
-}
writtenFixture : Bool -> Outcome
writtenFixture honest =
    runResolve honest Engine.emptyMemberTable [ 4 ] <|
        \_ -> mintOne (Vars.Structure (Vars.LambdaSet1 (Vars.LsMembers [ 9 ])))


{-| Resolves members `[4]` over one source that is top, with the rule on when
`honest` is True.
-}
topFixture : Bool -> Outcome
topFixture honest =
    runResolve honest Engine.emptyMemberTable [ 4 ] <|
        \_ -> mintOne (Vars.Structure (Vars.LambdaSet1 (Vars.LsTop 7)))


{-| Resolves members `[1]` over a cycle of two written sources, with the rule on
when `honest` is True.

Source `a` has members `[2]` and source `b`. Point `b` is created unwritten,
then set, before resolution, to no members and source `a`.

-}
cycleFixture : Bool -> Outcome
cycleFixture honest =
    runResolve honest Engine.emptyMemberTable [ 1 ] <|
        \_ ->
            UF.fresh (desc (Vars.FlexVar Nothing))
                |> IO.andThen
                    (\b ->
                        UF.fresh (desc (lsFrom [ 2 ] [ b ]))
                            |> IO.andThen
                                (\a ->
                                    UF.set b (desc (lsFrom [] [ a ]))
                                        |> IO.map (\_ -> [ a ])
                                )
                    )


{-| Resolves members `[1]` over the cycle of `cycleFixture`, except that `b`'s
sources are `a` and a third point that stays unwritten, with the rule on when
`honest` is True.
-}
cycleFlexFixture : Bool -> Outcome
cycleFlexFixture honest =
    runResolve honest Engine.emptyMemberTable [ 1 ] <|
        \_ ->
            UF.fresh (desc (Vars.FlexVar Nothing))
                |> IO.andThen
                    (\dangling ->
                        UF.fresh (desc (Vars.FlexVar Nothing))
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


{-| Resolves members `[4]` over one unwritten source, using `gcMemberTable`, so
the member is a standalone global, with the rule on when `honest` is True.
-}
gcFixture : Bool -> Outcome
gcFixture honest =
    runResolve honest gcMemberTable [ 4 ] <|
        \_ -> mintOne (Vars.FlexVar Nothing)


{-| A member table in which member id 4 is registered as a standalone global,
`author/project`'s `Test.target`, and nothing else is registered.
-}
gcMemberTable : Engine.LssMemberTable
gcMemberTable =
    let
        t =
            Engine.emptyMemberTable
    in
    { t
        | sources =
            Dict.insert 4
                (Engine.SourceGlobal (TOpt.Global (ModuleName.Canonical ( "author", "project" ) "Test") "target"))
                t.sources
    }



-- ====== HARNESS ======


{-| What one resolution reports: its members, `Nothing` for top, and the two
mixed-crossing counters read from the accumulator afterwards.

`mixed` is the store's `mixedFlex` and `mixedGc` its `mixedFlexGc`.

-}
type alias Outcome =
    { members : Maybe (List Int)
    , mixed : Int
    , mixedGc : Int
    }


{-| Returns what resolving `members0` reports, over the sources `mkSources`
creates, with the honest-sources rule on when `honest` is True and member
table `table`.

The sources are created in a fresh store, and the store as they leave it is
the one resolved over.

-}
runResolve : Bool -> Engine.LssMemberTable -> List Int -> (() -> IO.IO (List Vars.Variable)) -> Outcome
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
                                        Store.resolveSlotMembersWith honest members0 srcs (ctx table st)
                                in
                                { members = res
                                , mixed = counter .mixedFlex c
                                , mixedGc = counter .mixedFlexGc c
                                }
                            )
                )
        )


{-| Creates one point holding `content` and returns it as a one-source list.
-}
mintOne : Vars.Content -> IO.IO (List Vars.Variable)
mintOne content =
    UF.fresh (desc content) |> IO.map (\v -> [ v ])


{-| Builds a descriptor holding `content`, with no rank, no mark and no copy.
-}
desc : Vars.Content -> Vars.Descriptor
desc content =
    IO.makeDescriptor content Type.noRank Type.noMark Nothing


{-| Builds lambda-set content with members `members` and sources `sources`.
-}
lsFrom : List Int -> List Vars.Variable -> Vars.Content
lsFrom members sources =
    Vars.Structure (Vars.LambdaSet1 (Vars.LsFrom members sources))


{-| An action that returns the current store state and leaves it unchanged.
-}
captureState : IO.IO IO.State
captureState =
    \st -> ( st, st )


{-| Builds the context for one resolution over store state `st`, with member
table `table`.

`Store.resolveSlotMembersWith` reads only `store`, `lss` and `memberTable`;
the other fields are placeholders. `lss` holds an accumulator with every
counter at zero, which is what lets a mixed crossing be counted: with
`Nothing` there, none is. `lssOn` is True but is not read, since the rule is
the function's own argument.

-}
ctx : Engine.LssMemberTable -> IO.State -> ZonkCtxShape
ctx table st =
    { store = st
    , next = TypeIds.firstMVarId
    , lssOn = True
    , maxSetSize = 8
    , lss =
        Just
            { zonked = 0
            , widenedBySize = 0
            , hist = Dict.empty
            , widenedHist = Dict.empty
            , grounded = 0
            , groundingDeferred = 0
            , mixedFlex = 0
            , mixedFlexGc = 0
            , causeSet = 0
            , causePoison = 0
            , causeFlex = 0
            , causeEdgeSet = 0
            , causeEdgeEmpty = 0
            , causeEdgeTop = 0
            , causeUnknown = 0
            , multiSets = Dict.empty
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


{-| The context record `Store.resolveSlotMembersWith` takes, written out field
by field.

`Store` does not expose a name for it, and Elm accepts any record with the
same fields and types in its place, so this alias must list exactly the fields
of the store's own.

-}
type alias ZonkCtxShape =
    { store : IO.State
    , next : TypeIds.MVarId
    , lssOn : Bool
    , maxSetSize : Int
    , lss : Maybe LssAccShape
    , ecoReads : List Vars.Variable
    , intern : Intern.Intern
    , memberTable : Engine.LssMemberTable
    , nextMemberId : Int
    , arrowOf : Dict.Dict Int Int
    , varOf : Dict.Dict Int Int
    , nextVar : Int
    }


{-| The zonk accumulator held in the context's `lss` field, written out for the
same reason as `ZonkCtxShape`. The tests read only `mixedFlex` and
`mixedFlexGc`.
-}
type alias LssAccShape =
    { zonked : Int
    , widenedBySize : Int
    , hist : Dict.Dict Int Int
    , widenedHist : Dict.Dict Int Int
    , grounded : Int
    , groundingDeferred : Int
    , mixedFlex : Int
    , mixedFlexGc : Int
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


{-| Returns the counter `get` selects from the accumulator in `c`, or -1, which
no count can equal, when `c` holds no accumulator.
-}
counter : (LssAccShape -> Int) -> ZonkCtxShape -> Int
counter get c =
    case c.lss of
        Just acc ->
            get acc

        Nothing ->
            -1
