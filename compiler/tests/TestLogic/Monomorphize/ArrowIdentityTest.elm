module TestLogic.Monomorphize.ArrowIdentityTest exposing (suite)

{-| Tests of when two function arrows loaded into the solver's store share one
lambda-set slot. Getting this wrong changes the lambda sets the solver
computes: the sets of function values that can flow through each arrow.

When lambda sets are on, `Compiler.MonoSolver.Store.loadTypeC` gives each
`TLambda` it loads a _slot_, a store Point that will hold the set of function
values that can flow through that arrow. A `TLambda` carries an _ArrowId_, an
identity stamped on it before monomorphization, or `Can.noArrow` when it is
unstamped. The _arrow memo_ maps an ArrowId to the slot already minted for it,
so a second arrow with the same ArrowId can reuse that slot. Each load also
records its slots, and once that list is reversed (as `loadInto` does) each
arrow in the type has one _ordinal position_, in load order. How loads share
Points, and which per-item state is cleared around a scratch store, is stated in
`Compiler.MonoSolver.Store` and `Compiler.MonoSolver.Engine`. Three facts matter
here.

1.  A memo hit still adds an ordinal position, so the positions count arrows,
    not distinct slots, and it does not add to the count of minted slots. If
    the positions fell short, `LssInfer.applyFacts` would find a non-trivial
    signature's arrow count different from the slot count and set every lambda
    set of that instantiation to unknown, recording it only under
    `lss.report`.

2.  The isolated loads, `Store.loadTypeIsolated` and
    `Store.loadTypeIsolatedWithArrows`, start from an empty arrow memo and do
    not write theirs back. Two isolated loads of the same annotation would
    otherwise meet the same ArrowIds and share their slots, merging the lambda
    sets of separate call sites.

3.  The arrow memo holds Points, and the Points of every store are numbered
    from 0, so a memo carried into a _scratch store_ (a fresh store a pass runs
    in and then discards) names unrelated Points there. `Engine.clearedAux`
    empties it on entry and `Engine.restoredAux` puts back the outer one on
    exit.

The fixture types are built from `Int -> Int` arrows: one arrow alone, a pair
whose two arrows carry the same `ArrowSlot` (an ArrowId, or `Can.noArrow` on
both), and a pair with two different ArrowIds. Each load runs `loadTypeC` on
`Store.testLoadCtx` with lambda sets on, an empty variable memo and a given
arrow-memo seed, into a fresh store unless a test says otherwise. The tests
establish:

  - Two arrows sharing an ArrowId give two positions, one mint, and the same
    slot at both.
  - Two arrows with different ArrowIds give two positions, two mints, and
    different slots.
  - Two `Can.noArrow` arrows give two positions, two mints, different slots,
    and leave the arrow memo empty.
  - Loading one stamped arrow leaves one memo entry, and loading it again into
    another fresh store seeded with that memo records the same Point index as
    the first load and mints no slot, which shows the memo hit. The two stores
    differ, so this is not a shared slot.
  - Two loads of one stamped arrow into the same store, each seeded with an
    empty memo, give different slots.
  - The same two loads, the second seeded with the first's memo, give the same
    slot, and the second mints no slot.
  - `clearedAux` empties an arrow memo that held one entry.
  - `restoredAux` gives back the outer arrow memo, without the inner memo's
    entry.
  - `Engine.emptyItemAux` has an empty arrow memo.

Among what is not tested: which seed the four `Step`-typed load functions in
`Store` pass and whether they write the memo back (`sharedLoadCtx`,
`isolatedLoadCtx`, `writeBackShared`, `writeBackIsolated`); whether
`Engine.withScratchStore` and the re-translation in
`Compiler.MonoSolver.Translate` call `clearedAux` and `restoredAux`; that
`Engine.resetItem` installs `emptyItemAux`; the other store-scoped fields of
`Engine.ItemAux`; and loads with lambda sets off.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypeVars as Vars
import Compiler.Data.Id as Id
import Compiler.Elm.ModuleName as ModuleName
import Compiler.MonoSolver.Engine as Engine
import Compiler.MonoSolver.Store as Store
import Dict
import Expect
import System.TypeCheck.IO as IO
import Test exposing (Test)


{-| The tests, in three groups: the ordinal contract, an empty arrow-memo seed
against a shared one, and `clearedAux`, `restoredAux` and `emptyItemAux` on the
arrow memo.
-}
suite : Test
suite =
    Test.describe "Phase 2a arrow identity"
        [ Test.describe "1. the ordinal contract" ordinalPins
        , Test.describe "2. the isolation asymmetry" isolationPins
        , Test.describe "3. scratch-store isolation" scratchPins
        ]



-- ====== FIXTURES ======


{-| The type `Int` from `elm/core`'s `Basics`, the argument and result of every
fixture arrow.
-}
intType : Can.Type TypeIds.MVarId
intType =
    Can.TType (ModuleName.Canonical ( "elm", "core" ) "Basics") "Int" []


{-| Returns the type `Int -> Int` with `aid` as its `ArrowSlot`.
-}
arrowWith : TypeIds.ArrowSlot -> Can.Type TypeIds.MVarId
arrowWith aid =
    Can.TLambda aid intType intType


{-| Returns the type `( Int -> Int, Int -> Int )` with `aid` as the `ArrowSlot`
of both arrows.
-}
twinArrows : TypeIds.ArrowSlot -> Can.Type TypeIds.MVarId
twinArrows aid =
    Can.TTuple (arrowWith aid) (arrowWith aid) []


{-| The type `( Int -> Int, Int -> Int )` with `firstId` on the first arrow and
`secondId` on the second.
-}
distinctArrows : Can.Type TypeIds.MVarId
distinctArrows =
    Can.TTuple (arrowWith firstId) (arrowWith secondId) []


{-| The `ArrowSlot` stamped with the first ArrowId.
-}
firstId : TypeIds.ArrowSlot
firstId =
    TypeIds.Arrow TypeIds.firstArrowId


{-| The `ArrowSlot` stamped with the ArrowId after `firstId`'s.
-}
secondId : TypeIds.ArrowSlot
secondId =
    TypeIds.Arrow (Id.succ TypeIds.firstArrowId)


{-| What one load leaves behind that the tests look at: its slots by ordinal
position, how many it minted, its arrow memo afterwards, and its store.
-}
type alias Loaded =
    { keys : List Int -- the `slots`, as `Engine.pointKey`s
    , minted : Int
    , memo : Dict.Dict Int Vars.Variable -- the arrow memo, not the variable memo
    , slots : Array.Array Vars.Variable
    , store : IO.State
    }


{-| Loads `canType` into `store` with lambda sets on, starting from the arrow
memo `seedMemo` and an empty variable memo, and returns what the load left
behind.
-}
loadInto : Dict.Dict Int Vars.Variable -> Can.Type TypeIds.MVarId -> IO.State -> Loaded
loadInto seedMemo canType store =
    let
        ( _, c ) =
            Store.loadTypeC Dict.empty canType (Store.testLoadCtx True seedMemo store)

        slots =
            Array.fromList (List.reverse c.arrowSlots)
    in
    -- Nothing in a load is unified, so within one store different `pointKey`s
    -- mean different slots.
    { keys = List.map Engine.pointKey (Array.toList slots)
    , minted = c.slotsMinted
    , memo = c.arrowMemo
    , slots = slots
    , store = c.store
    }


{-| Loads `canType` as `loadInto` does, into a new empty store.
-}
loadFresh : Dict.Dict Int Vars.Variable -> Can.Type TypeIds.MVarId -> Loaded
loadFresh seedMemo canType =
    loadInto seedMemo canType (Engine.freshStore ())


{-| Returns a load's number of ordinal positions, its number of mints, and
whether it has exactly two positions holding the same slot.
-}
shape : Loaded -> ( Int, Int, Bool )
shape r =
    ( Array.length r.slots
    , r.minted
    , case r.keys of
        [ a, b ] ->
            a == b

        _ ->
            False
    )



-- ====== 1. ORDINAL CONTRACT ======


{-| The tests of the ordinal contract: positions and mints for shared, distinct
and unstamped ArrowIds, and the arrow memo a load leaves behind.
-}
ordinalPins : List Test
ordinalPins =
    [ Test.test "two arrows sharing one ArrowId: 2 positions, 1 mint, both the same slot" <|
        \() ->
            Expect.equal ( 2, 1, True ) (shape (loadFresh Dict.empty (twinArrows firstId)))
    , Test.test "distinct ArrowIds: 2 positions, 2 mints, DIFFERENT slots" <|
        \() ->
            Expect.equal ( 2, 2, False ) (shape (loadFresh Dict.empty distinctArrows))
    , Test.test "noArrowId ALWAYS misses and NEVER records (else every unstamped arrow collapses)" <|
        \() ->
            let
                r =
                    loadFresh Dict.empty (twinArrows Can.noArrow)
            in
            Expect.equal ( ( 2, 2, False ), True ) ( shape r, Dict.isEmpty r.memo )
    , Test.test "a miss INSERTS, so the memo carries the slot to the next load" <|
        \() ->
            let
                first =
                    loadFresh Dict.empty (arrowWith firstId)

                second =
                    loadFresh first.memo (arrowWith firstId)
            in
            Expect.equal ( 1, first.keys, 0 ) ( Dict.size first.memo, second.keys, second.minted )
    ]



-- ====== 2. ISOLATION ASYMMETRY ======


{-| The tests that an empty arrow-memo seed never reuses another load's slot,
while a seed holding that load's memo does.
-}
isolationPins : List Test
isolationPins =
    [ Test.test "an EMPTY seed never reuses another load's slot (H1: the isolated entries)" <|
        \() ->
            let
                a =
                    loadInto Dict.empty (arrowWith firstId) (Engine.freshStore ())

                b =
                    loadInto Dict.empty (arrowWith firstId) a.store
            in
            Expect.notEqual a.keys b.keys
    , Test.test "a SHARED seed DOES reuse it — the contrast that makes the asymmetry meaningful" <|
        \() ->
            let
                a =
                    loadInto Dict.empty (arrowWith firstId) (Engine.freshStore ())

                b =
                    loadInto a.memo (arrowWith firstId) a.store
            in
            Expect.equal ( a.keys, 0 ) ( b.keys, b.minted )
    ]



-- ====== 3. SCRATCH-STORE ISOLATION ======


{-| The two slots minted by loading `distinctArrows`, used as memo values in the
scratch-store tests. Those tests check which memo entries survive, not what the
Points are.
-}
samplePoints : Maybe ( Vars.Variable, Vars.Variable )
samplePoints =
    let
        r =
            loadFresh Dict.empty distinctArrows
    in
    Maybe.map2 Tuple.pair (Array.get 0 r.slots) (Array.get 1 r.slots)


{-| Returns `k` applied to the two `samplePoints`, or a failure if the load
recorded fewer than two slots.
-}
withSamples : (Vars.Variable -> Vars.Variable -> Expect.Expectation) -> Expect.Expectation
withSamples k =
    case samplePoints of
        Just ( a, b ) ->
            k a b

        Nothing ->
            Expect.fail "fixture broken: the two-arrow load did not mint two slots"


{-| Returns `Engine.emptyItemAux` with `memo` as its arrow memo.
-}
auxWith : Dict.Dict Int Vars.Variable -> Engine.ItemAux
auxWith memo =
    let
        aux =
            Engine.emptyItemAux
    in
    { aux | arrowMemo = memo }


{-| The tests of the arrow-memo field of `ItemAux`: `clearedAux` empties it,
`restoredAux` takes the outer one, and `emptyItemAux` starts with it empty.
-}
scratchPins : List Test
scratchPins =
    [ Test.test "clearedAux DROPS the arrow memo entering a scratch store" <|
        \() ->
            withSamples
                (\outerPt _ ->
                    let
                        aux =
                            auxWith (Dict.singleton 1 outerPt)
                    in
                    Expect.equal ( 1, True )
                        ( Dict.size aux.arrowMemo
                        , Dict.isEmpty (Engine.clearedAux aux).arrowMemo
                        )
                )
    , Test.test "restoredAux RESTORES the OUTER arrow memo, discarding the inner one" <|
        \() ->
            withSamples
                (\outerPt innerPt ->
                    let
                        outer =
                            auxWith (Dict.singleton 1 outerPt)

                        -- Stands for a memo the pass grew inside the scratch store.
                        innerGrown =
                            auxWith (Dict.singleton 99 innerPt)

                        restored =
                            Engine.restoredAux outer innerGrown
                    in
                    Expect.equal ( outer.arrowMemo, False )
                        ( restored.arrowMemo, Dict.member 99 restored.arrowMemo )
                )
    , Test.test "emptyItemAux starts empty (so resetItem clears it per item)" <|
        \() ->
            Expect.equal True (Dict.isEmpty Engine.emptyItemAux.arrowMemo)
    ]
