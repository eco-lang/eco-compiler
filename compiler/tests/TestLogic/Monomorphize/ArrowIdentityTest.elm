module TestLogic.Monomorphize.ArrowIdentityTest exposing (suite)

{-| Phase 2a — per-occurrence arrow identity
(`plans/lss-unknown-elimination.md` §4).

Three properties, none of which had a test before this phase: **nothing in the
suite pinned arrow ordinals by name or number, nothing pinned `lssRootAnn`, and
nothing pinned signature triviality**, which is why the plan calls these
mandatory rather than nice-to-have.

1.  **The ordinal contract (§4.3).** Two `TLambda` occurrences sharing one
    `ArrowId` must produce TWO ordinal positions holding ONE slot — pushed
    twice, minted once. A hit that skipped `arrowSlots` would shorten the array
    and `LssInfer.applyFacts` poisons the whole instantiation on a length
    mismatch, SILENTLY (`censusLenGuard` is report-gated). A hit that bumped
    `slotsMinted` would corrupt the dead-slot census.

2.  **The isolation asymmetry (§4.4).** A load seeded with an EMPTY arrow memo
    must never reuse another load's slot. This is the H1 collapse hazard:
    `LssInfer.sigSourceTypeFor` and the call path read the SAME annotation
    value out of `s.env.annotations`, so if the two isolated entry points
    (`loadTypeIsolated`, `loadTypeIsolatedWithArrows`) threaded the item's
    arrow memo, every call site of an annotated `f` would unify into ONE lambda
    set — monomorphic set analysis and maximal imprecision.

3.  **Scratch-store isolation (§4.5).** `arrowMemo` holds Points, and Point
    indices are dense from 0 in EVERY store, so it must be cleared entering a
    scratch store and restored leaving one. Leaking it aliases low outer Point
    indices and `zonkSigGo` then bakes garbage into a memoised `LssSignature`,
    which is GLOBAL and survives the whole run — a silent miscompile, not a
    crash.

**Deviation from the plan's sketch, recorded** (the `LssDirectedFlowTest`
precedent): properties 1 and 2 are driven through `Store.loadTypeC` against a
hand-built `LoadCtx` rather than through the four `Step`-typed entry points,
which would need a full `Engine.S`. What that leaves unpinned is one line per
entry point — which seed each passes and whether it writes back — and those
lines are `sharedLoadCtx` / `isolatedLoadCtx` / `writeBackShared` /
`writeBackIsolated` in `Store.elm`. Property 3 IS pinned exactly, because
`Engine.clearedAux` / `restoredAux` are pure `ItemAux` functions.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.TypeIds as TypeIds
import Compiler.Data.Id as Id
import Compiler.Elm.ModuleName as ModuleName
import Compiler.MonoSolver.Engine as Engine
import Compiler.MonoSolver.Store as Store
import Compiler.Type.Vars as Vars
import Dict
import Expect
import System.TypeCheck.IO as IO
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Phase 2a arrow identity"
        [ Test.describe "1. the ordinal contract" ordinalPins
        , Test.describe "2. the isolation asymmetry" isolationPins
        , Test.describe "3. scratch-store isolation" scratchPins
        ]



-- ====== FIXTURES ======


intType : Can.Type TypeIds.MVarId
intType =
    Can.TType (ModuleName.Canonical ( "elm", "core" ) "Basics") "Int" []


{-| `arrowWith aid` is `Int -> Int` stamped with `aid`.
-}
arrowWith : TypeIds.ArrowSlot -> Can.Type TypeIds.MVarId
arrowWith aid =
    Can.TLambda aid intType intType


{-| `( Int -> Int, Int -> Int )` where BOTH arrows carry the same `ArrowId` —
the shape a repeated load of one stamped type object produces.
-}
twinArrows : TypeIds.ArrowSlot -> Can.Type TypeIds.MVarId
twinArrows aid =
    Can.TTuple (arrowWith aid) (arrowWith aid) []


{-| The two arrows carry DIFFERENT ids: the ordinary case.
-}
distinctArrows : Can.Type TypeIds.MVarId
distinctArrows =
    Can.TTuple (arrowWith firstId) (arrowWith secondId) []


firstId : TypeIds.ArrowSlot
firstId =
    TypeIds.Arrow TypeIds.firstArrowId


secondId : TypeIds.ArrowSlot
secondId =
    TypeIds.Arrow (Id.succ TypeIds.firstArrowId)


{-| One load's observable result. A record rather than a tuple because Elm caps
tuples at three.
-}
type alias Loaded =
    { keys : List Int -- ordinal slot Points, by `Engine.pointKey`
    , minted : Int
    , memo : Dict.Dict Int Vars.Variable
    , slots : Array.Array Vars.Variable
    , store : IO.State
    }


loadInto : Bool -> Dict.Dict Int Vars.Variable -> Can.Type TypeIds.MVarId -> IO.State -> Loaded
loadInto arrowIdOn seedMemo canType store =
    let
        ( _, c ) =
            Store.loadTypeC Dict.empty canType (Store.testLoadCtx True arrowIdOn seedMemo store)

        slots =
            Array.fromList (List.reverse c.arrowSlots)
    in
    -- The slots are freshly minted here and nothing has been unified, so
    -- `pointKey` equality is exactly UF equivalence.
    { keys = List.map Engine.pointKey (Array.toList slots)
    , minted = c.slotsMinted
    , memo = c.arrowMemo
    , slots = slots
    , store = c.store
    }


loadFresh : Bool -> Dict.Dict Int Vars.Variable -> Can.Type TypeIds.MVarId -> Loaded
loadFresh arrowIdOn seedMemo canType =
    loadInto arrowIdOn seedMemo canType Engine.freshStore


{-| `( positions, mints, bothOrdinalsShareOneSlot )`.
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


ordinalPins : List Test
ordinalPins =
    [ Test.test "two arrows sharing one ArrowId: 2 positions, 1 mint, both the same slot" <|
        \() ->
            Expect.equal ( 2, 1, True ) (shape (loadFresh True Dict.empty (twinArrows firstId)))
    , Test.test "distinct ArrowIds: 2 positions, 2 mints, DIFFERENT slots" <|
        \() ->
            Expect.equal ( 2, 2, False ) (shape (loadFresh True Dict.empty distinctArrows))
    , Test.test "flag OFF: sharing an ArrowId changes nothing" <|
        \() ->
            let
                r =
                    loadFresh False Dict.empty (twinArrows firstId)
            in
            Expect.equal ( ( 2, 2, False ), True ) ( shape r, Dict.isEmpty r.memo )
    , Test.test "noArrowId ALWAYS misses and NEVER records (else every unstamped arrow collapses)" <|
        \() ->
            let
                r =
                    loadFresh True Dict.empty (twinArrows Can.noArrow)
            in
            Expect.equal ( ( 2, 2, False ), True ) ( shape r, Dict.isEmpty r.memo )
    , Test.test "a miss INSERTS, so the memo carries the slot to the next load" <|
        \() ->
            let
                first =
                    loadFresh True Dict.empty (arrowWith firstId)

                second =
                    loadFresh True first.memo (arrowWith firstId)
            in
            Expect.equal ( 1, first.keys, 0 ) ( Dict.size first.memo, second.keys, second.minted )
    ]



-- ====== 2. ISOLATION ASYMMETRY ======


isolationPins : List Test
isolationPins =
    [ Test.test "an EMPTY seed never reuses another load's slot (H1: the isolated entries)" <|
        \() ->
            -- What `loadTypeIsolatedWithArrows` does: seed `Dict.empty`, and
            -- never write the resulting memo back. Two such loads of the SAME
            -- annotation value must land on DISJOINT slots — otherwise every
            -- call site of an annotated `f` unifies into one lambda set.
            let
                a =
                    loadInto True Dict.empty (arrowWith firstId) Engine.freshStore

                b =
                    loadInto True Dict.empty (arrowWith firstId) a.store
            in
            Expect.notEqual a.keys b.keys
    , Test.test "a SHARED seed DOES reuse it — the contrast that makes the asymmetry meaningful" <|
        \() ->
            let
                a =
                    loadInto True Dict.empty (arrowWith firstId) Engine.freshStore

                b =
                    loadInto True a.memo (arrowWith firstId) a.store
            in
            Expect.equal ( a.keys, 0 ) ( b.keys, b.minted )
    ]



-- ====== 3. SCRATCH-STORE ISOLATION ======


{-| Two independently-minted slot Points, standing in for "an outer item's
arrow memo" and "a slot the scratch pass minted against ITS OWN store". The
Points are opaque here — the property under test is about the DICT, not about
what it names.
-}
samplePoints : Maybe ( Vars.Variable, Vars.Variable )
samplePoints =
    let
        r =
            loadFresh True Dict.empty distinctArrows
    in
    Maybe.map2 Tuple.pair (Array.get 0 r.slots) (Array.get 1 r.slots)


withSamples : (Vars.Variable -> Vars.Variable -> Expect.Expectation) -> Expect.Expectation
withSamples k =
    case samplePoints of
        Just ( a, b ) ->
            k a b

        Nothing ->
            Expect.fail "fixture broken: the two-arrow load did not mint two slots"


auxWith : Dict.Dict Int Vars.Variable -> Engine.ItemAux
auxWith memo =
    let
        aux =
            Engine.emptyItemAux
    in
    { aux | arrowMemo = memo }


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

                        -- The scratch pass minted its own entry against ITS
                        -- store; those Points are meaningless outside it.
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
