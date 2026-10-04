module Compiler.MonoSolver.Store exposing
    ( loadType, unifyStep, zonkToMono
    , rezonkSettled
    , LoadCtx, LssZonkAcc, SetWriteCtx, ZonkCtx, addSlotSource, aliasBodyEligible, aliasKeyOf, arrowParts, arrowSetSlot, classifyDirect, foldSetWrites, groundHash, groundNoArrow, groundNoArrowWith, loadTypeC, loadTypeIsolated, loadTypeIsolatedWithArrows, loadTypeS, loadTypeWithArrows, monoTypeToVarS, poisonArrowSets, qInferenceCensus, qOnFor, qShadowCensus, resolveSlotMembers, resolveSlotMembersWith, setWriteCtx, testLoadCtx, unifyBestEffortStoreS, unifySlotWithSet, unifySlotWithSetC, unifyStrict, unifyStrictS
    )

{-| The solver store operations: load a canonical type into the union-find,
encode a demanded MonoType as concrete structure, unify two Points, and read a
Point back to a MonoType.

The per-item memo (`MVarId -> Point`) is the propagation mechanism: every
occurrence of an MVarId loads to the SAME Point, so unifying one occurrence with
a concrete type resolves the whole class. This is why loading `add`'s
`number -> number -> number` (one shared `number` var) and unifying a single
`Int` argument concretizes the entire ABI.

`zonkToMono` reads a Point back, stamping residuals from live store content:
`FlexSuper Number → MVar id CNumber`, other residuals → `MVar id CEcoValue`
(the id taken from the first MVarId that minted the Point — `revMemo`). It never
defaults numbers; the shared Prune close does that (MONO\_028).

@docs loadType, unifyStep, zonkToMono
@docs rezonkSettled
@docs LoadCtx, LssZonkAcc, SetWriteCtx, ZonkCtx, addSlotSource, aliasBodyEligible, aliasKeyOf, arrowParts, arrowSetSlot, classifyDirect, foldSetWrites, groundHash, groundNoArrow, groundNoArrowWith, loadTypeC, loadTypeIsolated, loadTypeIsolatedWithArrows, loadTypeS, loadTypeWithArrows, monoTypeToVarS, poisonArrowSets, qInferenceCensus, qOnFor, qShadowCensus, resolveSlotMembers, resolveSlotMembersWith, setWriteCtx, testLoadCtx, unifyBestEffortStoreS, unifySlotWithSet, unifySlotWithSetC, unifyStrict, unifyStrictS

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.AST.Intern as Intern exposing (Intern)
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypeVars as Vars
import Compiler.Data.Id as Id
import Compiler.Elm.ModuleName as ModuleName
import Compiler.MonoSolver.Engine as Engine exposing (Failure(..), Step)
import Compiler.Type.Error as TErr
import Compiler.Type.Type as Type
import Compiler.Type.Unify as Unify
import Compiler.Type.UnionFind as UF
import Data.HashMap as HashMap
import Dict
import Eco.Hash
import System.TypeCheck.IO as IO



-- ====== LOAD: Can.Type -> store Point ======


{-| M3: bundle-threaded load. Loads a canonical type into the store returning its
root Point (mirroring the real solver's `srcTypeToVar` minus pools; each distinct
MVarId is memoized to one Point so shared vars share a Point). It recurses over an
N-node canonical type
minting a fresh Point per structural node and one per var; the former Step form
copied the whole 23-field `S` twice per node (a `freshVar` `liftIO` + a
`recordVar` `modifyS`). It now threads a 3-field `LoadCtx` internally and writes
`S` back exactly once — semantically identical (same Points minted in the same
order, same memo/revMemo updates), only cheaper.
-}
type alias LoadCtx =
    { store : IO.State
    , memo : Dict.Dict Int Vars.Variable
    , revMemo : Array (Maybe TypeIds.MVarId)
    , lssOn : Bool -- mint FunL set slots (lambda-set specialization)
    , arrowSlots : List Vars.Variable -- minted set slots, REVERSED minting order
    , slotsMinted : Int -- Phase 3 rider: unconstrained slot mints this load (sizes Phase 5's dead-slot population)
    , arrowMemo : Dict.Dict Int Vars.Variable -- Phase 2a: `Id.toComparable arrowId` -> that arrow's SET SLOT Point. SLOT ONLY, never the FunL node — see `loadTypeC`.
    , censusOn : Bool -- multi-set census (M3): mirror of `env.lss.report`. Gates `arrowOfSlot` ONLY; nothing else reads it.
    , arrowOfSlot : Dict.Dict Int Int -- multi-set census (M3): set-slot pointKey -> ArrowId. Report-gated; recorded in BOTH arrowIdentity arms.
    , groundLoads : HashMap.HashMap Engine.AliasKey Vars.FlatType -- step 4a: alias instantiation -> the ROOT content of its first load in THIS store. Store-scoped exactly like `arrowMemo`.
    , aliasMemo : HashMap.HashMap Engine.AliasKey Engine.AliasVerdict -- step 4b's per-RUN verdicts, read-only here: saves re-walking a body to decide eligibility.
    }


{-| A `LoadCtx` over a fresh store, for tests that drive `loadTypeC` directly
(the `LssDirectedFlowTest` precedent: store-level semantics are pinned at the
store level rather than through a pipeline fixture). `sharedArrowMemo` selects
the seed the four `Step`-typed entry points differ on — pass an item's memo to
model `loadType`/`loadTypeWithArrows`, `Dict.empty` to model the two isolated
entries.
-}
testLoadCtx : Bool -> Dict.Dict Int Vars.Variable -> IO.State -> LoadCtx
testLoadCtx lssOn sharedArrowMemo store =
    { store = store
    , memo = Dict.empty
    , revMemo = Array.empty
    , lssOn = lssOn
    , arrowSlots = []
    , slotsMinted = 0
    , arrowMemo = sharedArrowMemo
    , censusOn = False
    , arrowOfSlot = Dict.empty
    , groundLoads = HashMap.empty
    , aliasMemo = HashMap.empty
    }


{-| The SHARED-memo load seed: the item's var memo AND the item's arrow memo
(Phase 2a §4.4).
-}
sharedLoadCtx : Engine.S -> LoadCtx
sharedLoadCtx s =
    { store = s.store
    , memo = s.memo
    , revMemo = s.revMemo
    , lssOn = s.env.lss.enabled
    , arrowSlots = []
    , slotsMinted = 0
    , arrowMemo = s.itemAux.arrowMemo
    , censusOn = s.env.lss.report
    , arrowOfSlot = s.itemAux.arrowOfSlot
    , groundLoads = s.itemAux.groundLoads
    , aliasMemo = s.monoMemo.aliasMemo
    }


{-| The ISOLATED load seed — a fresh per-call-site instantiation.

**H1, the collapse hazard (Phase 2a §4.4): `arrowMemo` is `Dict.empty` here,
and the result is NEVER written back.** `LssInfer.sigSourceTypeFor` and the
call path read the SAME annotation value out of `s.env.annotations`, so
threading the item's arrow memo into an isolated load would make every call
site of an annotated `f` unify into ONE lambda set — monomorphic set analysis,
maximal imprecision, and `applyFacts` degenerating to self-unification. The
asymmetry mirrors the one these entries already have for `memo`.

-}
isolatedLoadCtx : Engine.S -> LoadCtx
isolatedLoadCtx s =
    { store = s.store
    , memo = Dict.empty
    , revMemo = s.revMemo
    , lssOn = s.env.lss.enabled
    , arrowSlots = []
    , slotsMinted = 0
    , arrowMemo = Dict.empty
    , censusOn = s.env.lss.report

    -- The census map is NOT isolated: an isolated load mints slots in the
    -- ITEM's store, and the census only ever reads it to name a slot. Sharing
    -- it costs nothing and keeps per-call-site instantiations attributable to
    -- their arrow — which is exactly the population the census exists to see.
    , arrowOfSlot = s.itemAux.arrowOfSlot

    -- `groundLoads` is NOT isolated, and for the same reason the census map is
    -- not: it holds GROUND structure, which has no set slot and no var, so the
    -- H1 collapse hazard that forces `arrowMemo` to be empty here does not
    -- apply. Sharing it is the whole point — an isolated per-call-site load of
    -- `S` should reuse the item's `S` Points.
    , groundLoads = s.itemAux.groundLoads
    , aliasMemo = s.monoMemo.aliasMemo
    }


{-| Write a SHARED load back: store, memos, the mint counter, and the item's
arrow memo. Flag-off this is byte-for-byte the previous single record update.
-}
writeBackShared : LoadCtx -> Engine.S -> Engine.S
writeBackShared c s =
    let
        s1 =
            if c.slotsMinted == 0 then
                { s | store = c.store, memo = c.memo, revMemo = c.revMemo }

            else
                let
                    stats =
                        s.lssStats
                in
                { s | store = c.store, memo = c.memo, revMemo = c.revMemo, lssStats = { stats | slotsMinted = stats.slotsMinted + c.slotsMinted } }
    in
    let
        aux =
            s1.itemAux
    in
    -- Unconditional since step 6: the guard was `arrowIdOn || censusOn`, and
    -- `arrowIdOn` was fixed True from the solver, so the branch was always
    -- taken.
    { s1 | itemAux = { aux | arrowMemo = c.arrowMemo, groundLoads = c.groundLoads, arrowOfSlot = c.arrowOfSlot } }


{-| Write an ISOLATED load back: store, revMemo, the mint counter — and
NEITHER memo (§4.4's H1).
-}
writeBackIsolated : LoadCtx -> Engine.S -> Engine.S
writeBackIsolated c s =
    let
        s1 =
            if c.slotsMinted == 0 then
                { s | store = c.store, revMemo = c.revMemo }

            else
                let
                    stats =
                        s.lssStats
                in
                { s | store = c.store, revMemo = c.revMemo, lssStats = { stats | slotsMinted = stats.slotsMinted + c.slotsMinted } }
    in
    -- NEITHER memo goes out (§4.4's H1) — but the census map does, so an
    -- isolated instantiation's slots can still be named by their arrow, and so
    -- does the ground-load memo: its Points live in the ITEM's store and are
    -- ground, so a later shared load should reuse them.
    if c.censusOn then
        let
            aux =
                s1.itemAux
        in
        { s1 | itemAux = { aux | arrowOfSlot = c.arrowOfSlot, groundLoads = c.groundLoads } }

    else
        let
            aux =
                s1.itemAux
        in
        { s1 | itemAux = { aux | groundLoads = c.groundLoads } }


loadTypeS : Can.Type TypeIds.MVarId -> Engine.S -> ( Vars.Variable, Engine.S )
loadTypeS canType s =
    -- Step 10b: `loadType` never fails, so this is the real function and the
    -- `Step` form below is a one-line adapter over it. A1 explicit trailing-S,
    -- tuple-literal leaf — the shape `$sret` promotion requires.
    let
        ( v, c ) =
            loadTypeC s.env.superStatic canType (sharedLoadCtx s)
    in
    ( v, writeBackShared c s )


loadType : Can.Type TypeIds.MVarId -> Step Vars.Variable
loadType canType s =
    loadTypeS canType s


{-| `loadType` additionally returning the minted arrow set slots in minting
order. **This function (with its isolated sibling) DEFINES arrow ordinals**
(LSS\_006): `LssSignature.arrows` and fact application both index by position
in this array. Shared item memo — unit members loaded through one memo share
annotation Points (the Σ self-reference rule).
-}
loadTypeWithArrows : Can.Type TypeIds.MVarId -> Engine.S -> ( ( Vars.Variable, Array Vars.Variable ), Engine.S )
loadTypeWithArrows canType s =
    -- Step 10e: A1 explicit trailing-S, tuple-literal leaf.
    let
        ( v, c ) =
            loadTypeC s.env.superStatic canType (sharedLoadCtx s)
    in
    ( ( v, Array.fromList (List.reverse c.arrowSlots) ), writeBackShared c s )


{-| `loadTypeIsolated` additionally returning the minted arrow set slots in
minting order (fresh per-call-site instantiation; see `loadTypeWithArrows`
for the ordinal contract).
-}
loadTypeIsolatedWithArrows : Can.Type TypeIds.MVarId -> Engine.S -> ( ( Vars.Variable, Array Vars.Variable ), Engine.S )
loadTypeIsolatedWithArrows canType s =
    -- Step 10e: A1 explicit trailing-S, tuple-literal leaf.
    let
        ( v, c ) =
            loadTypeC s.env.superStatic canType (isolatedLoadCtx s)
    in
    ( ( v, Array.fromList (List.reverse c.arrowSlots) ), writeBackIsolated c s )


{-| D8: load a scheme with an ISOLATED (empty) memo so its vars do not share
Points with the surrounding item — a fresh instantiation — writing `S` back
ONCE. Replaces `Translate.instantiate`'s three S-copies (memo:=empty, loadType's
internal write, memo-restore) with a single write: the isolated memo is threaded
internally and discarded, and `s.memo` is never touched. Byte-identical (same
Points minted in the same order; store + revMemo updated; memo unchanged).
-}
loadTypeIsolated : Can.Type TypeIds.MVarId -> Engine.S -> ( Vars.Variable, Engine.S )
loadTypeIsolated canType s =
    -- Step 10e: A1 explicit trailing-S, tuple-literal leaf.
    let
        ( v, c ) =
            loadTypeC s.env.superStatic canType (isolatedLoadCtx s)
    in
    ( v, writeBackIsolated c s )


loadTypeC : Dict.Dict Int Vars.SuperType -> Can.Type TypeIds.MVarId -> LoadCtx -> ( Vars.Variable, LoadCtx )
loadTypeC superStatic canType c0 =
    case canType of
        Can.TVar mvarId ->
            loadVarC superStatic mvarId c0

        Can.TLambda arrowSlot from to ->
            let
                ( pFrom, c1 ) =
                    loadTypeC superStatic from c0

                ( pTo, c2 ) =
                    loadTypeC superStatic to c1
            in
            if c2.lssOn then
                -- LSS: slot every arrow. The unconstrained FlexVar slot reads
                -- back as UNKNOWN at zonk; ordinals = arrow POSITION in
                -- `arrowSlots` (LSS_006).
                --
                -- Phase 2a (`plans/lss-unknown-elimination.md` §4.2/§4.3): with
                -- `arrowIdentity` on, a repeated load of the SAME stamped type
                -- object reuses the slot the first load minted, so lambda sets
                -- travel with the type instead of fragmenting per load.
                --
                -- MEMOISE THE SET SLOT ONLY, NEVER THE `FunL` NODE. The
                -- structure Point must still be minted per load: `from`/`to`
                -- can resolve to different Points on different loads (leaf-memo
                -- differences, alias binding in the `TAlias Holey` arm below),
                -- and sharing the node would union unrelated argument types.
                --
                -- The hit/miss contract, all four rows load-bearing:
                --
                --   event               arrowSlots  slotsMinted  arrowMemo
                --   miss (id on)        push        +1           insert
                --   HIT  (id on)        push        unchanged    unchanged
                --   NoArrow (id on)   push        +1           NEVER insert
                --   id off              push        +1           untouched
                --
                -- A hit that SKIPPED `arrowSlots` would shorten the ordinal
                -- array and `LssInfer.applyFacts` poisons the whole
                -- instantiation on a length mismatch — SILENTLY, because
                -- `censusLenGuard` is report-gated. A hit that BUMPED
                -- `slotsMinted` would corrupt the mint counter feeding the
                -- dead-slot census.
                --
                -- NEW AND EXPECTED: the ordinal array can now hold the SAME
                -- Point twice. `applyFactsGo`/`repOrdinal` cope (repOrdinal
                -- already reports the smallest UF-equivalent ordinal), but
                -- `LssSignature.trivial` goes false more often, reducing the
                -- `trivial` short-circuit rate. Expect a small COMPILE-TIME
                -- cost and do not misread it as a precision change.
                let
                    -- Phase 2a/2b: the arrow's global identity, or 0 when the
                    -- slot is unstamped. `SolverRoot` cannot appear here — it
                    -- is resolved to `Arrow` by `AssignMVarIds`, and this is a
                    -- `Can.Type MVarId`.
                    -- The CENSUS key: always the occurrence id (0 = the
                    -- `NoArrow` "unstamped" sentinel). `noteArrow` and the
                    -- MSET census key on corpus-stable occurrence ArrowIds —
                    -- the Run-AE lesson — so root keying must never leak in
                    -- here (plans/lss-solver-root-signature-identity.md
                    -- §2.4b: memo key ≠ census key, two values).
                    occKey =
                        case arrowSlot of
                            TypeIds.Arrow aid ->
                                Id.toComparable aid + 1

                            _ ->
                                0

                    -- The MEMO key IS the occurrence key. `lss.sigRootIdentity`
                    -- used to translate it through a solver-root side table
                    -- inside the inference scratch; that flag and its table
                    -- were deleted 2026-09-17 (`arrowSolverRoots` already
                    -- gives solver-unified arrows one shared ArrowId upstream,
                    -- in `AssignMVarIds`).
                    memoKey =
                        occKey

                    -- Multi-set census (M3): name this slot by its ARROW, so
                    -- the zonk can report per-POSITION rather than
                    -- per-readback (plan §2.5.5). Report-gated, and
                    -- `NoArrow` (0) is never recorded — it names nothing.
                    -- Recorded in BOTH `arrowIdentity` arms: the ArrowId comes
                    -- from `AssignMVarIds` and is flag-independent, which is
                    -- what makes it a valid cross-arm join key. Under root
                    -- keying a shared slot is attributed to its LAST-loaded
                    -- occurrence (Dict.insert overwrites) — an attribution
                    -- smear the census reader must know about, not a defect.
                    noteArrow pSet cIn =
                        if cIn.censusOn && occKey /= 0 then
                            { cIn | arrowOfSlot = Dict.insert (Engine.pointKey pSet) occKey cIn.arrowOfSlot }

                        else
                            cIn

                    mintFresh cIn =
                        let
                            ( pSet, cOut ) =
                                freshVarC (Vars.FlexVar Nothing) cIn
                        in
                        structC (Vars.FunL pFrom pTo pSet)
                            (noteArrow pSet { cOut | arrowSlots = pSet :: cOut.arrowSlots, slotsMinted = cOut.slotsMinted + 1 })
                in
                if memoKey == 0 then
                    -- `NoArrow` (an arrow built outside
                    -- `AssignMVarIds`): ALWAYS miss, NEVER record in
                    -- `arrowMemo` — otherwise every unstamped arrow in a type
                    -- collapses into one slot.
                    mintFresh c2

                else
                    case Dict.get memoKey c2.arrowMemo of
                        Just pSet ->
                            structC (Vars.FunL pFrom pTo pSet)
                                (noteArrow pSet { c2 | arrowSlots = pSet :: c2.arrowSlots })

                        Nothing ->
                            let
                                ( pSet, c3 ) =
                                    freshVarC (Vars.FlexVar Nothing) c2
                            in
                            structC (Vars.FunL pFrom pTo pSet)
                                (noteArrow pSet
                                    { c3
                                        | arrowSlots = pSet :: c3.arrowSlots
                                        , slotsMinted = c3.slotsMinted + 1
                                        , arrowMemo = Dict.insert memoKey pSet c3.arrowMemo
                                    }
                                )

            else
                structC (Vars.Fun1 pFrom pTo) c2

        Can.TType canonical name args ->
            let
                ( pArgs, c1 ) =
                    loadListC superStatic args c0
            in
            structC (Vars.App1 (normalizePrimHome canonical name) name pArgs) c1

        Can.TRecord fields maybeExtension ->
            let
                ( pExt, c1 ) =
                    loadRecordExtC superStatic maybeExtension c0

                ( pFields, c2 ) =
                    loadRecordFieldsC superStatic (Dict.toList fields) c1
            in
            structC (Vars.Record1 pFields pExt) c2

        Can.TUnit ->
            structC Vars.Unit1 c0

        Can.TTuple a b rest ->
            let
                ( pa, c1 ) =
                    loadTypeC superStatic a c0

                ( pb, c2 ) =
                    loadTypeC superStatic b c1

                ( pRest, c3 ) =
                    loadListC superStatic rest c2
            in
            structC (Vars.Tuple1 pa pb pRest) c3

        Can.TAlias home name args aliasType ->
            -- Step 4a: the second and later loads of one ground, arrow-free alias
            -- instantiation WITHIN an item reuse the first load's child Points and
            -- mint only a fresh root. For the compiler's own `S` that is one mint
            -- instead of one per field and per nested subtree.
            --
            -- Only the CHILDREN are shared; the root is always fresh. Sharing a root
            -- would let two vars that today land in separate union-find classes — a
            -- bare reference's family var and a call's isolated twin — become
            -- equivalent through it, which flips the MONO_029 stale-read barrier and
            -- livelocks the saturation loop. Per-load roots keep them apart, and one
            -- `fresh` is nothing against the mints it replaces.
            --
            -- Var Points are never shared (an eligible type has no `TVar`), and no
            -- arrow is reachable, so `arrowSlots`/`arrowMemo`/`slotsMinted` and the
            -- LSS_006 ordinal contract are not touched.
            case aliasKeyOf home name args of
                Nothing ->
                    loadAliasPlainC superStatic args aliasType c0

                Just key ->
                    case HashMap.get Engine.aliasKeyHash Engine.aliasKeyEq key c0.groundLoads of
                        Just flat ->
                            structC flat c0

                        Nothing ->
                            let
                                eligible =
                                    case HashMap.get Engine.aliasKeyHash Engine.aliasKeyEq key c0.aliasMemo of
                                        Just (Engine.AliasGround _) ->
                                            True

                                        Just Engine.AliasIneligible ->
                                            False

                                        Nothing ->
                                            aliasBodyEligible aliasType

                                ( p, c1 ) =
                                    loadAliasPlainC superStatic args aliasType c0
                            in
                            if not eligible then
                                ( p, c1 )

                            else
                                -- `p` was minted by this very load and nothing has
                                -- unified it, so this is a root read.
                                let
                                    ( store1, desc ) =
                                        UF.get p c1.store
                                in
                                case desc.content of
                                    Vars.Structure flat ->
                                        ( p
                                        , { c1
                                            | groundLoads = HashMap.insert Engine.aliasKeyHash Engine.aliasKeyEq key flat c1.groundLoads
                                          }
                                        )

                                    _ ->
                                        -- Unreachable for an eligible body, whose root
                                        -- is always a Structure. Degrade to "not
                                        -- memoised" rather than crash.
                                        ( p, { c1 | store = store1 } )


{-| The two alias arms as they were before step 4a.
-}
loadAliasPlainC : Dict.Dict Int Vars.SuperType -> List ( TypeIds.MVarId, Can.Type TypeIds.MVarId ) -> Can.AliasType TypeIds.MVarId -> LoadCtx -> ( Vars.Variable, LoadCtx )
loadAliasPlainC superStatic args aliasType c0 =
    case aliasType of
        Can.Filled inner ->
            loadTypeC superStatic inner c0

        Can.Holey inner ->
            -- Bind each alias parameter to its argument's loaded Point, load the
            -- body, then restore the prior memo bindings (params are alias-local).
            let
                ( argPoints, c1 ) =
                    loadListC superStatic (List.map Tuple.second args) c0

                bindings =
                    List.map2 (\( paramId, _ ) pt -> ( Engine.mvarIdKey paramId, pt )) args argPoints

                saved =
                    List.map (\( k, _ ) -> ( k, Dict.get k c1.memo )) bindings

                c2 =
                    { c1 | memo = List.foldl (\( k, v ) m -> Dict.insert k v m) c1.memo bindings }

                ( pInner, c3 ) =
                    loadTypeC superStatic inner c2

                restoredMemo =
                    List.foldl
                        (\( k, mv ) m ->
                            case mv of
                                Just v ->
                                    Dict.insert k v m

                                Nothing ->
                                    Dict.remove k m
                        )
                        c3.memo
                        saved
            in
            ( pInner, { c3 | memo = restoredMemo } )


freshVarC : Vars.Content -> LoadCtx -> ( Vars.Variable, LoadCtx )
freshVarC content c =
    let
        ( store1, pt ) =
            UF.fresh (IO.makeDescriptor content Type.outermostRank Type.noMark Nothing) c.store
    in
    ( pt, { c | store = store1 } )


structC : Vars.FlatType -> LoadCtx -> ( Vars.Variable, LoadCtx )
structC flat c =
    freshVarC (Vars.Structure flat) c


{-| Load or reuse the Point for a type variable, minting from the STATIC super
truth only (see the Step-era note; taint is consulted at zonk time, never here).
-}
loadVarC : Dict.Dict Int Vars.SuperType -> TypeIds.MVarId -> LoadCtx -> ( Vars.Variable, LoadCtx )
loadVarC superStatic mvarId c =
    let
        key =
            Engine.mvarIdKey mvarId
    in
    case Dict.get key c.memo of
        Just pt ->
            ( pt, c )

        Nothing ->
            let
                content =
                    case Dict.get key superStatic of
                        Just superType ->
                            Vars.FlexSuper superType Nothing

                        Nothing ->
                            Vars.FlexVar Nothing

                ( pt, c1 ) =
                    freshVarC content c
            in
            ( pt, recordVarC key mvarId pt c1 )


recordVarC : Int -> TypeIds.MVarId -> Vars.Variable -> LoadCtx -> LoadCtx
recordVarC key mvarId pt c =
    { c
        | memo = Dict.insert key pt c.memo
        , revMemo =
            -- A2: keep-first semantics on the point-indexed Array (== the former
            -- `Dict.member pk` guard): a filled slot is left untouched.
            revMemoSetIfAbsent (Engine.pointKey pt) mvarId c.revMemo
    }


{-| A2: record `mvarId` at point index `pk` unless that slot is already filled
(first-writer-wins). Grows the Array with `Nothing` up to `pk` as needed.
-}
revMemoSetIfAbsent : Int -> TypeIds.MVarId -> Array (Maybe TypeIds.MVarId) -> Array (Maybe TypeIds.MVarId)
revMemoSetIfAbsent pk mvarId arr =
    case Array.get pk arr of
        Just (Just _) ->
            arr

        _ ->
            let
                len =
                    Array.length arr
            in
            if pk < len then
                Array.set pk (Just mvarId) arr

            else
                Array.append arr (Array.push (Just mvarId) (Array.repeat (pk - len) Nothing))


loadListC : Dict.Dict Int Vars.SuperType -> List (Can.Type TypeIds.MVarId) -> LoadCtx -> ( List Vars.Variable, LoadCtx )
loadListC superStatic types c0 =
    case types of
        [] ->
            ( [], c0 )

        t :: rest ->
            let
                ( p, c1 ) =
                    loadTypeC superStatic t c0

                ( ps, c2 ) =
                    loadListC superStatic rest c1
            in
            ( p :: ps, c2 )


loadRecordExtC : Dict.Dict Int Vars.SuperType -> Maybe TypeIds.MVarId -> LoadCtx -> ( Vars.Variable, LoadCtx )
loadRecordExtC superStatic maybeExtension c =
    case maybeExtension of
        Just extMvarId ->
            loadVarC superStatic extMvarId c

        Nothing ->
            structC Vars.EmptyRecord1 c


loadRecordFieldsC : Dict.Dict Int Vars.SuperType -> List ( String, Can.FieldType TypeIds.MVarId ) -> LoadCtx -> ( Dict.Dict String Vars.Variable, LoadCtx )
loadRecordFieldsC superStatic fields c0 =
    List.foldl
        (\( k, Can.FieldType _ t ) ( acc, c ) ->
            let
                ( pt, c1 ) =
                    loadTypeC superStatic t c
            in
            ( Dict.insert k pt acc, c1 )
        )
        ( Dict.empty, c0 )
        fields


{-| Normalize elm/core primitive type homes to a single canonical so the real
`Unify` treats them uniformly — the old engine classifies elm/core types by name
alone (ignoring the module), so e.g. `String.String` and `Basics.String` are the
same type there. Without this, `Unify` (which compares App1 homes) would reject
those benign home differences. Non-primitive (custom) elm/core types keep their
real home, which is needed for `Mono.mCustom`.
-}
normalizePrimHome : ModuleName.Canonical -> String -> ModuleName.Canonical
normalizePrimHome canonical name =
    case canonical of
        ModuleName.Canonical ( "elm", "core" ) _ ->
            case name of
                "Int" ->
                    ModuleName.basics

                "Float" ->
                    ModuleName.basics

                "Bool" ->
                    ModuleName.basics

                -- Char/String/List must normalize to the SAME canonical the real
                -- `Unify` uses for its comparable/appendable super checks
                -- (`Error.isString`=ModuleName.string, `isChar`=ModuleName.char,
                -- `isList`=ModuleName.list); using Basics here would make Unify
                -- reject `comparable ~ String/Char`.
                "Char" ->
                    ModuleName.char

                "String" ->
                    ModuleName.string

                "List" ->
                    ModuleName.list

                _ ->
                    canonical

        _ ->
            canonical



-- ====== ENCODE: MonoType -> concrete store Point ======


{-| PHASE 3 pre-pass: mint ONE store slot per distinct set VARIABLE in a type.

`monoTypeToVarC` then resolves every `LVar n` to that slot, which is what
carries the paper's α across the annotation round trip: two arrows the store
unified zonk to the same `n` (`varNumberFor`), so re-encoding gives them one
slot again.

A PRE-PASS rather than threaded state, deliberately: the encoder threads
`IO.State` only, and a read-only map keeps it that way — no state-threading
change at any of its call sites.

-}
mintVarSlots : Bool -> Mono.MonoType -> IO.State -> ( Dict.Dict Int Vars.Variable, IO.State )
mintVarSlots lssOn monoType st =
    if not lssOn then
        ( Dict.empty, st )

    else
        collectVarSlots monoType ( Dict.empty, st )


collectVarSlots : Mono.MonoType -> ( Dict.Dict Int Vars.Variable, IO.State ) -> ( Dict.Dict Int Vars.Variable, IO.State )
collectVarSlots monoType soFar =
    case monoType of
        Mono.MFunction _ anno args result ->
            let
                afterAnno =
                    case ( anno, soFar ) of
                        ( Mono.LVar n, ( acc, st ) ) ->
                            if Dict.member n acc then
                                soFar

                            else
                                let
                                    ( pSet, st1 ) =
                                        freshVarS (Vars.FlexVar Nothing) st
                                in
                                ( Dict.insert n pSet acc, st1 )

                        _ ->
                            soFar
            in
            List.foldl collectVarSlots (collectVarSlots result afterAnno) args

        Mono.MList _ inner ->
            collectVarSlots inner soFar

        Mono.MTuple _ elems ->
            List.foldl collectVarSlots soFar elems

        Mono.MRecord _ fields ->
            Dict.foldl (\_ t a -> collectVarSlots t a) soFar fields

        Mono.MCustom _ _ _ args ->
            List.foldl collectVarSlots soFar args

        _ ->
            soFar


{-| Encode a demanded MonoType as concrete store structure, the dual of the
`zonkToMono` classification. M6.0: threads only the store (`monoTypeToVar` mints
structure Points but touches neither memo nor revMemo), writing `S` back once
instead of once per node. Byte-identical (same Points minted in the same order).
-}
monoTypeToVarS : Mono.MonoType -> Engine.S -> ( Vars.Variable, Engine.S )
monoTypeToVarS monoType s =
    -- Step 10e: A1 explicit trailing-S, tuple-literal leaf. Never fails.
    let
        ( varSlots, storeWithVars ) =
            mintVarSlots s.env.lss.enabled monoType s.store

        ( v, store1 ) =
            monoTypeToVarC s.env.lss.enabled varSlots monoType storeWithVars
    in
    ( v, { s | store = store1 } )


freshVarS : Vars.Content -> IO.State -> ( Vars.Variable, IO.State )
freshVarS content st =
    let
        ( store1, pt ) =
            UF.fresh (IO.makeDescriptor content Type.outermostRank Type.noMark Nothing) st
    in
    ( pt, store1 )


structS : Vars.FlatType -> IO.State -> ( Vars.Variable, IO.State )
structS flat st =
    freshVarS (Vars.Structure flat) st


monoTypeToVarC : Bool -> Dict.Dict Int Vars.Variable -> Mono.MonoType -> IO.State -> ( Vars.Variable, IO.State )
monoTypeToVarC lssOn varSlots monoType st =
    case monoType of
        Mono.MInt ->
            structS (Vars.App1 ModuleName.basics "Int" []) st

        Mono.MFloat ->
            structS (Vars.App1 ModuleName.basics "Float" []) st

        Mono.MBool ->
            structS (Vars.App1 ModuleName.basics "Bool" []) st

        Mono.MChar ->
            structS (Vars.App1 ModuleName.char "Char" []) st

        Mono.MString ->
            structS (Vars.App1 ModuleName.string "String" []) st

        Mono.MUnit ->
            structS Vars.Unit1 st

        Mono.MList _ inner ->
            let
                ( p, st1 ) =
                    monoTypeToVarC lssOn varSlots inner st
            in
            structS (Vars.App1 ModuleName.list "List" [ p ]) st1

        Mono.MTuple _ elems ->
            case elems of
                a :: b :: rest ->
                    let
                        ( pa, st1 ) =
                            monoTypeToVarC lssOn varSlots a st

                        ( pb, st2 ) =
                            monoTypeToVarC lssOn varSlots b st1

                        ( pRest, st3 ) =
                            monoListToVarC lssOn varSlots rest st2
                    in
                    structS (Vars.Tuple1 pa pb pRest) st3

                _ ->
                    -- Degenerate tuple; encode as a fresh var rather than crash.
                    freshVarS (Vars.FlexVar Nothing) st

        Mono.MRecord _ fields ->
            let
                ( pFields, st1 ) =
                    recordFieldPointsC lssOn varSlots (Dict.toList fields) st

                ( ext, st2 ) =
                    structS Vars.EmptyRecord1 st1
            in
            structS (Vars.Record1 pFields ext) st2

        Mono.MCustom _ home name args ->
            let
                ( pArgs, st1 ) =
                    monoListToVarC lssOn varSlots args st
            in
            structS (Vars.App1 home name pArgs) st1

        Mono.MFunction _ anno args result ->
            -- Fold args right-to-left into nested Fun1 (one arg per arrow).
            -- Under lss, fold into FunL whose slots carry the annotation's
            -- content. Deliberate asymmetry with zonkSetSlot: a DEMAND's LTop
            -- encodes as top=True (poison — "some caller was widened, this
            -- arrow must stay dynamic"), while an UNKNOWN annotation encodes
            -- as an untouched slot, exactly as `loadTypeC` mints one.
            let
                ( pResult, st1 ) =
                    monoTypeToVarC lssOn varSlots result st
            in
            if lssOn then
                let
                    -- The store CONTENT every set slot of this arrow spine is
                    -- minted with.
                    --
                    -- PHASE 1b (plans/lss-unknown-elimination.md §3.4): this
                    -- site used to re-encode an unknown annotation as an
                    -- explicit `LsTop`, and that was HOP 3 of the laundering
                    -- chain in §0.1 — an unconstrained slot reads back as
                    -- unknown, the all-⊤ demand keys onto one shared key per
                    -- type shape, and the re-encode turns "never written" into
                    -- terminal, absorbing poison that the body then inherits
                    -- and re-exports through its own call demands. It bypassed
                    -- `unifySlotWithSetC` entirely, which is why
                    -- `setWriteTopJoin` read 2 against 152,890 `causePoison`
                    -- readbacks.
                    --
                    -- Minting a bare `FlexVar` keeps the slot RECOVERABLE: a
                    -- later LSS_010 join or a retranslation can still fill it,
                    -- where poison is terminal. LSS_007 holds unchanged — a
                    -- `FunL` slot holding a bare `FlexVar` is already the
                    -- normal case (`loadTypeC` mints exactly that) — but this
                    -- is the first time the DEMAND path produces one.
                    --
                    -- `Mono.unionAnno`/`annoCovers` flip to the height-2
                    -- lattice in the same commit as this line, and must never
                    -- be separated from it in either order: once the two ⊤
                    -- labels carry different ENCODINGS, keep-first would let a
                    -- stored `LUnknown` absorb a genuinely-poisoned `LTop`
                    -- demand and seed a bare flex slot where a caller demanded
                    -- poison.
                    slotContent =
                        case anno of
                            Mono.LTop tpK ->
                                -- §4.9: transport the ⊤ kind into the store
                                -- via the shared per-kind CAF contents.
                                IO.lsTopContentK tpK

                            Mono.LVar _ ->
                                -- Fallback only: reached when the pre-pass
                                -- minted no slot for this variable. Fresh flex
                                -- loses SHARING, never soundness.
                                Vars.FlexVar Nothing

                            Mono.LSet members ->
                                -- Phase 2: the LSet list IS the store
                                -- representation — reused by pointer, no
                                -- Dict.fromList conversion.
                                Vars.Structure (Vars.LambdaSet1 (Vars.LsMembers members))

                            Mono.LPartial _ ->
                                -- lss-lpartial §2/AR-P4: the store keeps
                                -- COMPLETE semantics in v1 — a lower bound
                                -- re-enters as fresh flex (members dropped at
                                -- this boundary; encoding them as LsMembers
                                -- would claim completeness). Partials are
                                -- terminal observations at the annotation
                                -- layer.
                                Vars.FlexVar Nothing

                    -- PHASE 3 (plans/lss-set-variable.md): a set VARIABLE
                    -- resolves to the ONE slot `mintVarSlots` made for it, so
                    -- every arrow carrying `LVar n` in this type shares a slot.
                    -- THAT is what makes the annotation round trip PRESERVE a
                    -- store unification instead of destroying it — Phase 1's
                    -- anonymous `LUnknown` minted a fresh slot per arrow and
                    -- lost the sharing every single time.
                    mintSlot stA =
                        case anno of
                            Mono.LVar n ->
                                case Dict.get n varSlots of
                                    Just pSet ->
                                        ( pSet, stA )

                                    Nothing ->
                                        freshVarS slotContent stA

                            _ ->
                                freshVarS slotContent stA
                in
                List.foldl
                    (\argType ( accPoint, stA ) ->
                        let
                            ( pa, stA1 ) =
                                monoTypeToVarC lssOn varSlots argType stA

                            ( pSet, stA2 ) =
                                mintSlot stA1
                        in
                        structS (Vars.FunL pa accPoint pSet) stA2
                    )
                    ( pResult, st1 )
                    (List.reverse args)

            else
                List.foldl
                    (\argType ( accPoint, stA ) ->
                        let
                            ( pa, stA1 ) =
                                monoTypeToVarC lssOn varSlots argType stA
                        in
                        structS (Vars.Fun1 pa accPoint) stA1
                    )
                    ( pResult, st1 )
                    (List.reverse args)

        Mono.MVar _ Mono.CNumber ->
            freshVarS (Vars.FlexSuper Vars.Number Nothing) st

        Mono.MVar _ Mono.CEcoValue ->
            freshVarS (Vars.FlexVar Nothing) st


monoListToVarC : Bool -> Dict.Dict Int Vars.Variable -> List Mono.MonoType -> IO.State -> ( List Vars.Variable, IO.State )
monoListToVarC lssOn varSlots types st =
    case types of
        [] ->
            ( [], st )

        t :: rest ->
            let
                ( p, st1 ) =
                    monoTypeToVarC lssOn varSlots t st

                ( ps, st2 ) =
                    monoListToVarC lssOn varSlots rest st1
            in
            ( p :: ps, st2 )


recordFieldPointsC : Bool -> Dict.Dict Int Vars.Variable -> List ( String, Mono.MonoType ) -> IO.State -> ( Dict.Dict String Vars.Variable, IO.State )
recordFieldPointsC lssOn varSlots fields st =
    List.foldl
        (\( k, t ) ( acc, stA ) ->
            let
                ( pt, stA1 ) =
                    monoTypeToVarC lssOn varSlots t stA
            in
            ( Dict.insert k pt acc, stA1 )
        )
        ( Dict.empty, st )
        fields



-- ====== UNIFY ======


{-| Deep type rendering for unify-mismatch diagnostics (E9 crash hunt made
the shallow kind-only message insufficient; the full shape names the bug).
-}
errDeep : TErr.Type -> String
errDeep t =
    case t of
        TErr.Lambda a b cs ->
            "(" ++ String.join " -> " (List.map errDeep (a :: b :: cs)) ++ ")"

        TErr.Type _ name args ->
            if List.isEmpty args then
                name

            else
                name ++ "<" ++ String.join "," (List.map errDeep args) ++ ">"

        TErr.FlexVar n ->
            "?" ++ n

        TErr.RigidVar n ->
            "!" ++ n

        TErr.FlexSuper _ n ->
            "?s" ++ n

        TErr.RigidSuper _ n ->
            "!s" ++ n

        TErr.Infinite ->
            "INF"

        TErr.Error ->
            "ERR"

        TErr.Record _ _ ->
            "{..}"

        TErr.Unit ->
            "()"

        TErr.Tuple _ _ _ ->
            "(,,)"

        TErr.Alias _ name _ real ->
            "~" ++ name ++ "=" ++ errDeep real


{-| Unify two store Points, reporting only whether it worked.

This is the direct-state entry: no `Step`, no `Result`, no rendered error. A
failing unify leaves the store as the attempt left it, so **a caller that means
to recover must bracket the call** with `Engine.markStore` / `rollbackStore` —
the store is mutated in place, so there is no older value to fall back to.
`unifyStrict` below is the entry for callers that propagate the failure instead.

-}
unifyStep : Vars.Variable -> Vars.Variable -> Engine.S -> ( Bool, Engine.S )
unifyStep v1 v2 s0 =
    let
        ( ok, store1 ) =
            Unify.unifyBoolS v1 v2 s0.store
    in
    ( ok, { s0 | store = store1 } )


{-| Unify two store Points, failing the item on a mismatch with the diagnostic
the monomorphizer renders. This is `unifyStep` as it was before step 5a: the
error types are built only on the failure path, so the success path — which is
almost all of them — no longer pays for the machinery that reported them.
-}
unifyStrict : Vars.Variable -> Vars.Variable -> Step ()
unifyStrict v1 v2 s0 =
    ( (), unifyStrictS (\() -> "") v1 v2 s0 )


{-| Step 10c: `unifyStrict` as a crash, with a caller-supplied context THUNK.

`UnifyMismatch` is manufactured only here. It is RECOVERED at exactly three
places (`unifyBestEffort`, `Translate.unifyBestEffortS`, `Translate.classifyRef`),
which read a `Bool` and never see this function; everywhere else a mismatch
aborts the build, so once the enclosing function stops carrying a `Result` the
abort is a process abort with the same rendered text.

`ctx` stays a thunk (D3): the diagnostic's recursive `canKind`/`monoKind` walks
are built ONLY on the aborting path, never on the ~100 %-success hot path.

-}
unifyStrictS : (() -> String) -> Vars.Variable -> Vars.Variable -> Engine.S -> Engine.S
unifyStrictS ctx v1 v2 s0 =
    let
        ( answer, store1 ) =
            Unify.unifyS v1 v2 s0.store

        s =
            { s0 | store = store1 }
    in
    case answer of
        Unify.AnswerOk _ ->
            s

        Unify.AnswerErr _ t1 t2 ->
            -- Diagnostic context: the spec being translated + flush state
            Engine.crashFailure
                (UnifyMismatch
                    ("unify-fail "
                        ++ errDeep t1
                        ++ " /vs/ "
                        ++ errDeep t2
                        ++ " [in "
                        ++ (case s.currentGlobal of
                                Just g ->
                                    Mono.toComparableGlobal g

                                Nothing ->
                                    "?"
                           )
                        ++ " joinRounds="
                        ++ String.fromInt s.lssStats.joinRounds
                        ++ " retrans="
                        ++ String.fromInt s.lssStats.retranslations
                        ++ "]"
                        ++ (case ctx () of
                                "" ->
                                    ""

                                c ->
                                    " | " ++ c
                           )
                    )
                )


unifyBestEffortStoreS : Vars.Variable -> Vars.Variable -> Engine.S -> Engine.S
unifyBestEffortStoreS v1 v2 s =
    let
        -- Bind the MARKED state and roll THAT back, never the pre-mark `s`.
        -- Under the kernel the two would behave alike (one store, mutated in
        -- place, and `s.store` is the same handle), but under the pure twin a
        -- handle is a VALUE: `s` does not carry the mark, and rolling it back
        -- is "rollback without a mark". `sM` differs from `s` only in the
        -- store, so the non-store fields this arm returns are unchanged.
        sM =
            Engine.markStore s
    in
    case unifyStep v1 v2 sM of
        ( True, s1 ) ->
            Engine.commitStore s1

        ( False, s1 ) ->
            -- Roll back the state the attempt RETURNED, not the pre-mark one:
            -- both name the same mutable store, but only this one carries the
            -- mark under the pure twin.
            Engine.rollbackStore s1



-- ====== LSS ARROW HELPERS ======


{-| The (param, rest) of an arrow content, whichever arrow form it is. The
single dispatch point that lets param-walkers handle `Fun1` and `FunL`
uniformly (identical Fun1 semantics when lss is off).
-}
arrowParts : Vars.Content -> Maybe ( Vars.Variable, Vars.Variable )
arrowParts content =
    case content of
        Vars.Structure (Vars.Fun1 pParam pRest) ->
            Just ( pParam, pRest )

        Vars.Structure (Vars.FunL pParam pRest _) ->
            Just ( pParam, pRest )

        _ ->
            Nothing


{-| The set slot of a slotted arrow's content (Nothing for `Fun1` — no slot
to constrain — and for non-arrows).
-}
arrowSetSlot : Vars.Content -> Maybe Vars.Variable
arrowSetSlot content =
    case content of
        Vars.Structure (Vars.FunL _ _ slot) ->
            Just slot

        _ ->
            Nothing


{-| Unify a set slot with the join of its content and `(top, members)`.

Phase 2 (`plans/lss-set-write-substrate.md`): every live case is a DIRECT
root-descriptor operation — read the root (already done here), compute the
join, `UF.set` the root. The join is total (no mismatch branch), runs no
occurs check, and rank/mark are invariant on every MonoSolver path (all mint
sites use `outermostRank`/`noMark`; `Unify.merge`'s min-rank is a no-op), so
funneling it through a fresh Point + full `unifyStep` — the pre-Phase-2 slow
path, 29.9 % of writes in Run B — bought nothing but allocation. `UF.set`
resolves chains to the root exactly as the FlexVar arm always has.

Counter mapping (§2.5): `skip` = ⊤-absorb + already-⊆; `flex` = adopt into
an unconstrained slot (⊤-onto-flex included); `topJoin` = ⊤ onto members;
`union` = real merge (incl. superset adoption); `slow` = the defensive arm
ONLY. Each bump rides the S copy its arm already makes.

-}
unifySlotWithSet : Maybe Int -> List Int -> Vars.Variable -> Engine.S -> Engine.S
unifySlotWithSet top members slot s0 =
    -- Phase 3: one thin wrapper over the ctx-threaded engine — a single S
    -- rebuild per call, exactly as before.
    foldSetWrites (unifySlotWithSetC top members slot (setWriteCtx (qOnFor s0) s0.store)) s0


{-| Phase 3 (`plans/lss-set-write-substrate.md`): store-level set-write
context. Threads the UF store plus counter DELTAS through a traversal so the
caller pays ONE ~6-field ctx copy per write and ONE S copy per traversal,
instead of a full ~32-field S copy per write (`poisonGo` paid one per
VISITED NODE). `needSlow` collects defensive-arm requests — measured 0 on
the self-compile (Run C `setWriteSlow=0`) — for the Step-shaped fallback at
the boundary; deferral reorders any such write to traversal end, which is
unobservable while the arm stays dead.
-}
type alias SetWriteCtx =
    { store : IO.State
    , skip : Int
    , flex : Int
    , topJoin : Int
    , union : Int

    -- §5.1 `Q` in shadow mode. `qOn` is `lss.report`; with it False nothing is
    -- appended and the only cost is one Bool in the ctx copy.
    , qOn : Bool
    , qLog : List Engine.QEntry
    }


{-| §5.1: the shadow-`Q` gate. Report-gated exactly like `arrowOfSlot` and
`zonkLog`, so a default build records nothing and every byte-identity rail is
untouched.
-}
qOnFor : Engine.S -> Bool
qOnFor s =
    s.env.lss.enabled && s.env.lss.qCensus


setWriteCtx : Bool -> IO.State -> SetWriteCtx
setWriteCtx qOn store =
    { store = store, skip = 0, flex = 0, topJoin = 0, union = 0, qOn = qOn, qLog = [] }


{-| §5.1: record one inclusion constraint against `slot`, capturing the slot's
content BEFORE the write (see `Engine.QPre` for why the seed is load-bearing).
-}
noteQ : Bool -> List Int -> Vars.Variable -> Vars.Descriptor -> SetWriteCtx -> SetWriteCtx
noteQ top members slot desc c =
    if not c.qOn then
        c

    else
        let
            pre =
                qPreOf desc

            entry =
                if top then
                    Engine.QTop slot pre

                else
                    Engine.QMembers slot members pre
        in
        { c | qLog = entry :: c.qLog }


qPreOf : Vars.Descriptor -> Engine.QPre
qPreOf desc =
    case desc.content of
        Vars.Structure (Vars.LambdaSet1 (Vars.LsTop _)) ->
            Engine.PreTop

        Vars.Structure (Vars.LambdaSet1 (Vars.LsMembers ms)) ->
            Engine.PreMembers ms

        Vars.Structure (Vars.LambdaSet1 (Vars.LsFrom ms _)) ->
            Engine.PreMembers ms

        _ ->
            Engine.PreFlex


{-| Fold a traversal's writes back into `S` with ONE copy, then run any
deferred defensive-arm writes through the Step-shaped slow path.
-}
foldSetWrites : SetWriteCtx -> Engine.S -> Engine.S
foldSetWrites c s0 =
    let
        stats0 =
            s0.lssStats

        -- §5.1: carry the traversal's shadow constraints into the item log.
        -- Empty (and therefore free) unless `lss.report`.
        withQ sN =
            case c.qLog of
                [] ->
                    sN

                entries ->
                    let
                        aux =
                            sN.itemAux
                    in
                    { sN | itemAux = { aux | qLog = entries ++ aux.qLog } }
    in
    withQ <|
        if c.skip == 0 && c.flex == 0 && c.topJoin == 0 && c.union == 0 then
            { s0 | store = c.store }

        else
            { s0
                | store = c.store
                , lssStats =
                    { stats0
                        | setWriteSkip = stats0.setWriteSkip + c.skip
                        , setWriteFlex = stats0.setWriteFlex + c.flex
                        , setWriteTopJoin = stats0.setWriteTopJoin + c.topJoin
                        , setWriteUnion = stats0.setWriteUnion + c.union
                    }
            }


{-| The set-write engine (join semantics and counter mapping exactly as the
Phase 2 Step form; see that commit's doc). Total on live content; the
defensive arm defers to the boundary via `needSlow`.
-}
unifySlotWithSetC : Maybe Int -> List Int -> Vars.Variable -> SetWriteCtx -> SetWriteCtx
unifySlotWithSetC top members slot c0 =
    let
        ( store1, desc ) =
            UF.get slot c0.store

        -- §5.1: `Q` is recorded HERE, before the join, because this is the one
        -- place that sees the constraint AND the slot's prior content. Every
        -- arm below (skip / flex / topJoin / union / needSlow) is downstream
        -- of it, so no eager write can escape the shadow log.
        c1 =
            noteQ (top /= Nothing) members slot desc { c0 | store = store1 }
    in
    case desc.content of
        Vars.Structure (Vars.LambdaSet1 (Vars.LsTop _)) ->
            -- ⊤ absorbs everything (terminal): pure skip. Kind-wise this is
            -- FIRST-⊤-WINS (no in-store priority rewrite on the hot skip
            -- arm — §4.9 records the census consequence).
            { c1 | skip = c1.skip + 1 }

        Vars.Structure (Vars.LambdaSet1 (Vars.LsMembers cur)) ->
            case top of
                Just topK ->
                    setRootC slot desc (IO.lsTopContentK topK) { c1 | topJoin = c1.topJoin + 1 }

                Nothing ->
                    case IO.classifySorted members cur of
                        Vars.SortedEqual ->
                            { c1 | skip = c1.skip + 1 }

                        Vars.SortedSub ->
                            -- members ⊆ cur (covers members == [] too).
                            { c1 | skip = c1.skip + 1 }

                        Vars.SortedSuper ->
                            -- cur ⊆ members: the union IS the caller's list —
                            -- adopt it by pointer, no merge allocation.
                            setRootC slot desc (Vars.Structure (Vars.LambdaSet1 (Vars.LsMembers members))) { c1 | union = c1.union + 1 }

                        Vars.SortedMixed ->
                            setRootC slot desc (Vars.Structure (Vars.LambdaSet1 (Vars.LsMembers (IO.unionSortedAsc members cur)))) { c1 | union = c1.union + 1 }

        Vars.Structure (Vars.LambdaSet1 (Vars.LsFrom cur srcs)) ->
            -- LSS_023: a member write onto an edge-carrying slot unions into
            -- the members field and leaves the SOURCES untouched — LSS_013
            -- spine injection lands here unchanged. This arm is MANDATORY,
            -- not defensive: without it the `_` fallback would reroute to
            -- `needSlow` → `unifyStep`, a silent behavior change. ⊤ absorbs
            -- and DROPS the sources (⊤ ⊇ everything — sound; also the arm
            -- that tops a poisoned honesty-hub target, which is what §7's
            -- `pick` fixture depends on).
            case top of
                Just topK ->
                    setRootC slot desc (IO.lsTopContentK topK) { c1 | topJoin = c1.topJoin + 1 }

                Nothing ->
                    case IO.classifySorted members cur of
                        Vars.SortedEqual ->
                            { c1 | skip = c1.skip + 1 }

                        Vars.SortedSub ->
                            { c1 | skip = c1.skip + 1 }

                        _ ->
                            setRootC slot desc (Vars.Structure (Vars.LambdaSet1 (Vars.LsFrom (IO.unionSortedAsc members cur) srcs))) { c1 | union = c1.union + 1 }

        Vars.FlexVar _ ->
            -- The DOMINANT case (Run B: 70.1 %): LSS_006 makes loadType mint
            -- fresh arrow structure per load, so a set write almost always
            -- targets an unconstrained flex slot. Adopt the content directly;
            -- the caller's list is stored AS-IS (ascending at every caller).
            case top of
                Just topK ->
                    setRootC slot desc (IO.lsTopContentK topK) { c1 | flex = c1.flex + 1 }

                Nothing ->
                    case members of
                        [] ->
                            -- (Nothing, []) is bottom: a no-op that keeps the
                            -- slot unconstrained, preserving
                            -- LsMembers-non-empty.
                            { c1 | skip = c1.skip + 1 }

                        _ ->
                            setRootC slot desc (Vars.Structure (Vars.LambdaSet1 (Vars.LsMembers members))) { c1 | flex = c1.flex + 1 }

        _ ->
            -- DEFENSIVE only: unreachable by closure of the slot-content
            -- channels (LSS_007), and measured 0 on every self-compile since
            -- Run C. It used to defer to a slow unify at the traversal
            -- boundary, which cost a `needSlow` list, a fold and a counter for
            -- a path that never runs. Writing ⊤ here is sound in the same
            -- direction the deferral was: ⊤ absorbs, so an over-approximation
            -- loses precision and never drops an edge.
            case top of
                Just topK ->
                    setRootC slot desc (IO.lsTopContentK topK) { c1 | topJoin = c1.topJoin + 1 }

                Nothing ->
                    setRootC slot desc IO.lsTopContent { c1 | topJoin = c1.topJoin + 1 }


setRootC : Vars.Variable -> Vars.Descriptor -> Vars.Content -> SetWriteCtx -> SetWriteCtx
setRootC slot desc content c =
    let
        ( store1, () ) =
            UF.set slot { desc | content = content } c.store
    in
    { c | store = store1 }


{-| §5.1 `Q` IN SHADOW MODE (plans/lss-paper-inclusion-constraints.md): solve
the item's recorded constraints and compare the result with what the eager
union actually left in the store.

READ-ONLY, exactly as `rezonkSettled` is: the threaded store (which `UF.repr`
path-compresses) is DROPPED and only counters cross the boundary. If that ever
changes, the census becomes a behaviour change wearing a census's clothes and
every byte-identity rail in the arc is silently invalid.

**Grouping is by `UF.repr` at item end**, which is the whole point: two slots
the solver unified are ONE σ, exactly as they are one variable in the paper.
Comparing per raw Point would report unification itself as a divergence.

**The comparison is against the RAW least solution**, not against what
`zonkSetSlot` hands back. The reader applies policy on top — LSS\_026(a)'s
honest-∅ widening and the `maxSetSize` cap both turn a perfectly good set into
`⊤` at READ time. Those are consumer decisions, not the eager union's answer,
and folding them in here would score policy as constraint-solving error.

-}
qShadowCensus : Engine.S -> Engine.S
qShadowCensus s =
    qCensusInto False (maybeList s.itemAux.qSigRoot) s


{-| §5.6: the same census, run INSIDE the inference scratch store over the
unit's own signature roots. This is where the paper's `Q` lives — inference —
and it is the arm the `REPRODUCES` gate is about. `qShadowCensus` scores the
specialization phase instead, where ground `σ̄` legitimately re-enters.
-}
qInferenceCensus : List Vars.Variable -> Engine.S -> Engine.S
qInferenceCensus roots s =
    qCensusInto True roots s


maybeList : Maybe a -> List a
maybeList m =
    case m of
        Just x ->
            [ x ]

        Nothing ->
            []


qCensusInto : Bool -> List Vars.Variable -> Engine.S -> Engine.S
qCensusInto toInfer roots s =
    if not (qOnFor s) then
        s

    else
        case s.itemAux.qLog of
            [] ->
                s

            entries ->
                let
                    -- The replay below only READS the store, but reading a
                    -- union-find reaches path compression, and the store is
                    -- now mutated in place rather than copied — so the writes
                    -- would outlive the census instead of being dropped with
                    -- the discarded array. Compression is observationally
                    -- invisible (same roots, same descriptors), but a census
                    -- must leave no trace at all, so the whole replay runs
                    -- inside an undo scope that is rolled back on the way out.
                    sM =
                        Engine.markStore s

                    acc =
                        -- `entries` is in reverse record order, so folding from
                        -- the head visits newest first and the OLDEST write of
                        -- each Point lands last — which is exactly the seed we
                        -- want (`Dict.insert` overwrites).
                        List.foldl qStep (qAcc0 sM.store) entries

                    solved =
                        qSolve acc

                    ( sigClasses, storeSig ) =
                        List.foldl
                            (\r ( accCls, stAcc ) ->
                                let
                                    ( cls, stN ) =
                                        qSigClasses (Just r) stAcc
                                in
                                ( Dict.union cls accCls, stN )
                            )
                            ( Dict.empty, acc.store )
                            roots

                    ( counts, _ ) =
                        qCompare sigClasses { acc | store = storeSig } solved

                    stats =
                        s.lssStats

                    sig =
                        stats.sigStats

                    prev =
                        if toInfer then
                            sig.qInfer

                        else
                            sig.qShadow

                    updated =
                        { items = prev.items + 1
                        , members = prev.members + acc.nMembers
                        , tops = prev.tops + acc.nTops
                        , edges = prev.edges + acc.nEdges
                        , classes = prev.classes + counts.classes
                        , agree = prev.agree + counts.agree
                        , divergeSuper = prev.divergeSuper + counts.divergeSuper
                        , divergeSub = prev.divergeSub + counts.divergeSub
                        , divergeTop = prev.divergeTop + counts.divergeTop
                        , divergeOther = prev.divergeOther + counts.divergeOther
                        , unresolved = prev.unresolved + counts.unresolved
                        , edgeClasses = prev.edgeClasses + counts.edgeClasses
                        , sigRoots =
                            prev.sigRoots
                                + (if List.isEmpty roots then
                                    0

                                   else
                                    1
                                  )
                        , reaching = prev.reaching + counts.reaching
                        , internal = prev.internal + counts.internal
                        , subMerged = prev.subMerged + counts.subMerged
                        , subUnseen = prev.subUnseen + counts.subUnseen
                        , internAgree = prev.internAgree + counts.internAgree
                        , internDiverge = prev.internDiverge + counts.internDiverge
                        , divergeSamples =
                            if List.length prev.divergeSamples >= 40 then
                                prev.divergeSamples

                            else
                                prev.divergeSamples ++ counts.samples
                        , scratchDropped = prev.scratchDropped
                        }
                in
                Engine.rollbackStore
                    { sM
                        | lssStats =
                            { stats
                                | sigStats =
                                    if toInfer then
                                        { sig | qInfer = updated }

                                    else
                                        { sig | qShadow = updated }
                            }
                    }


{-| §5.1 / §3.1: the set-slot classes the def's SIGNATURE reaches.

Walks the root type Point stashed by `Translate.demandUnifyRoot`, collecting
every `FunL` set slot and mapping it to its `UF.repr` class key. That is the
paper's partition criterion stated directly — _"variables not reaching the
signature are internalized"_ — and it is deliberately a REACHABILITY walk over
the type, not a rank test (§5.0b built ranks, measured them, and reverted:
the paper has one generalization boundary, so Rémy's levels have nothing to
separate).

-}
qSigClasses : Maybe Vars.Variable -> IO.State -> ( Dict.Dict Int (), IO.State )
qSigClasses root store0 =
    case root of
        Nothing ->
            ( Dict.empty, store0 )

        Just v ->
            let
                ( _, acc, store1 ) =
                    qSigGo Dict.empty Dict.empty v store0
            in
            ( acc, store1 )


qSigGo : Dict.Dict Int () -> Dict.Dict Int () -> Vars.Variable -> IO.State -> ( Dict.Dict Int (), Dict.Dict Int (), IO.State )
qSigGo seen acc v store0 =
    let
        raw =
            Engine.pointKey v
    in
    if Dict.member raw seen then
        ( seen, acc, store0 )

    else
        let
            ( store1, desc ) =
                UF.get v store0

            seen1 =
                Dict.insert raw () seen

            descend vars st =
                List.foldl (\x ( sn, an, stn ) -> qSigGo sn an x stn) ( seen1, acc, st ) vars
        in
        case desc.content of
            Vars.Structure flat ->
                case flat of
                    Vars.FunL arg res slot ->
                        let
                            ( store2, reprVar ) =
                                UF.repr slot store1

                            acc1 =
                                Dict.insert (Engine.pointKey reprVar) () acc
                        in
                        List.foldl (\x ( sn, an, stn ) -> qSigGo sn an x stn) ( seen1, acc1, store2 ) [ arg, res, slot ]

                    Vars.Fun1 arg res ->
                        descend [ arg, res ] store1

                    Vars.App1 _ _ args ->
                        descend args store1

                    Vars.Record1 fields ext ->
                        descend (ext :: Dict.values fields) store1

                    Vars.Tuple1 a b rest ->
                        descend (a :: b :: rest) store1

                    Vars.EmptyRecord1 ->
                        ( seen1, acc, store1 )

                    Vars.Unit1 ->
                        ( seen1, acc, store1 )

                    Vars.LambdaSet1 _ ->
                        ( seen1, acc, store1 )

            _ ->
                ( seen1, acc, store1 )


{-| One σ's value in the shadow solution: Eco's `⊤` plus a member set.
-}
type alias QAns =
    { top : Bool, members : List Int }


qBot : QAns
qBot =
    { top = False, members = [] }


qJoin : QAns -> QAns -> QAns
qJoin a b =
    if a.top || b.top then
        { top = True, members = [] }

    else
        { top = False, members = IO.unionSortedAsc a.members b.members }


qOfPre : Engine.QPre -> QAns
qOfPre pre =
    case pre of
        Engine.PreFlex ->
            qBot

        Engine.PreTop ->
            { top = True, members = [] }

        Engine.PreMembers ms ->
            { top = False, members = ms }


type alias QAcc =
    { store : IO.State
    , seedByPoint : Dict.Dict Int Engine.QPre -- RAW pointKey -> its content before its first constraint
    , reprOf : Dict.Dict Int Int -- RAW pointKey -> repr key at item end
    , reprVar : Dict.Dict Int Vars.Variable -- repr key -> that class's representative Point (there is no key -> Point inverse)
    , direct : Dict.Dict Int QAns -- repr key -> contribution of the ℓ ⋸ σ / ⊤ ⋸ σ constraints
    , edges : List ( Int, Int ) -- ( dst repr, src repr )
    , edgeDsts : Dict.Dict Int () -- repr keys that got an edge but no direct member write
    , nMembers : Int
    , nTops : Int
    , nEdges : Int

    -- Every member id this item recorded ANYWHERE, for the divergence split
    -- below: a member missing from a class but present elsewhere in Q arrived
    -- by UNIFICATION of two set slots (a path that does not go through
    -- `unifySlotWithSetC`); a member missing and unseen came from a slot
    -- minted with content and never constrained at all.
    , allMembers : Dict.Dict Int ()
    }


qAcc0 : IO.State -> QAcc
qAcc0 store =
    { store = store, seedByPoint = Dict.empty, reprOf = Dict.empty, reprVar = Dict.empty, direct = Dict.empty, edges = [], edgeDsts = Dict.empty, nMembers = 0, nTops = 0, nEdges = 0, allMembers = Dict.empty }


{-| Resolve a Point to its class key, remembering the mapping and its seed.
-}
qKey : Vars.Variable -> Engine.QPre -> QAcc -> ( Int, QAcc )
qKey v pre a =
    let
        ( _, reprVar ) =
            UF.repr v a.store

        raw =
            Engine.pointKey v

        key =
            Engine.pointKey reprVar
    in
    ( key
    , { a
        | seedByPoint = Dict.insert raw pre a.seedByPoint
        , allMembers =
            case pre of
                Engine.PreMembers ms ->
                    List.foldl (\m d -> Dict.insert m () d) a.allMembers ms

                _ ->
                    a.allMembers
        , reprOf = Dict.insert raw key a.reprOf
        , reprVar = Dict.insert key reprVar a.reprVar
      }
    )


qAddDirect : Int -> QAns -> QAcc -> QAcc
qAddDirect key ans a =
    { a | direct = Dict.insert key (qJoin ans (Maybe.withDefault qBot (Dict.get key a.direct))) a.direct }


qStep : Engine.QEntry -> QAcc -> QAcc
qStep entry a0 =
    case entry of
        Engine.QMembers slot members pre ->
            let
                ( key, a1 ) =
                    qKey slot pre a0
            in
            qAddDirect key
                { top = False, members = members }
                { a1
                    | nMembers = a1.nMembers + 1
                    , allMembers = List.foldl (\m d -> Dict.insert m () d) a1.allMembers members
                }

        Engine.QTop slot pre ->
            let
                ( key, a1 ) =
                    qKey slot pre a0
            in
            qAddDirect key { top = True, members = [] } { a1 | nTops = a1.nTops + 1 }

        Engine.QEdge dst src preDst preSrc ->
            let
                ( dstKey, a1 ) =
                    qKey dst preDst a0

                ( srcKey, a2 ) =
                    qKey src preSrc a1
            in
            { a2
                | edges = ( dstKey, srcKey ) :: a2.edges
                , edgeDsts = Dict.insert dstKey () a2.edgeDsts
                , nEdges = a2.nEdges + 1
            }


{-| The least solution of the recorded constraints:
`S(α) = seed(α) ⊔ {ℓ | ℓ ⋸ α} ⊔ ⋃ over the edges into α`.

Iterated to a fixpoint. The lattice is finite (flat member ids, plus ⊤) and
every step is monotone, so it terminates; the round cap is a backstop against a
malformed log, never a semantic limit, and hitting it can only under-report a
member — the direction that shows up as `divergeSub`, i.e. loudly.

-}
qSolve : QAcc -> Dict.Dict Int QAns
qSolve a =
    let
        base =
            Dict.foldl
                (\raw pre acc ->
                    case Dict.get raw a.reprOf of
                        Just key ->
                            Dict.insert key (qJoin (qOfPre pre) (Maybe.withDefault qBot (Dict.get key acc))) acc

                        Nothing ->
                            acc
                )
                a.direct
                a.seedByPoint

        step cur =
            List.foldl
                (\( dstKey, srcKey ) acc ->
                    case Dict.get srcKey acc of
                        Just srcAns ->
                            Dict.insert dstKey (qJoin srcAns (Maybe.withDefault qBot (Dict.get dstKey acc))) acc

                        Nothing ->
                            acc
                )
                cur
                a.edges

        go n cur =
            if n <= 0 then
                cur

            else
                let
                    next =
                        step cur
                in
                if next == cur then
                    cur

                else
                    go (n - 1) next
    in
    go (List.length a.edges + 1) base


type alias QCounts =
    { classes : Int, agree : Int, divergeSuper : Int, divergeSub : Int, divergeTop : Int, divergeOther : Int, unresolved : Int, edgeClasses : Int, reaching : Int, internal : Int, subMerged : Int, subUnseen : Int, internAgree : Int, internDiverge : Int, samples : List String }


qCounts0 : QCounts
qCounts0 =
    { classes = 0, agree = 0, divergeSuper = 0, divergeSub = 0, divergeTop = 0, divergeOther = 0, unresolved = 0, edgeClasses = 0, reaching = 0, internal = 0, subMerged = 0, subUnseen = 0, internAgree = 0, internDiverge = 0, samples = [] }


qCompare : Dict.Dict Int () -> QAcc -> Dict.Dict Int QAns -> ( QCounts, IO.State )
qCompare sigClasses a solved =
    Dict.foldl
        (\key shadow ( c0, store0 ) ->
            let
                ( eager, store1 ) =
                    qEagerAt (Dict.get key a.reprVar) store0

                c1 =
                    { c0
                        | classes = c0.classes + 1
                        , edgeClasses =
                            if Dict.member key a.edgeDsts && not (Dict.member key a.direct) then
                                c0.edgeClasses + 1

                            else
                                c0.edgeClasses

                        -- The paper's partition (§3.1): reached by the
                        -- signature => quantified into `ᾱ`; not reached =>
                        -- internalized to `S(Q,α)`.
                        , reaching =
                            if Dict.member key sigClasses then
                                c0.reaching + 1

                            else
                                c0.reaching
                        , internal =
                            if Dict.member key sigClasses then
                                c0.internal

                            else
                                c0.internal + 1
                    }
            in
            case eager of
                Nothing ->
                    -- Still unconstrained at item end: the eager answer is not
                    -- DEFINED, so the gate says nothing about it. This is §5.1's
                    -- third census item — what a per-item store cannot settle.
                    ( { c1 | unresolved = c1.unresolved + 1 }, store1 )

                Just ans ->
                    -- §5.3: score the INTERNAL population separately. Those are
                    -- the classes the paper would replace with `S(Q,α)`, so
                    -- whether that substitution is safe is decided by how often
                    -- the shadow solution equals the eager one THERE, not
                    -- overall.
                    ( qScore a.allMembers (not (Dict.member key sigClasses)) shadow ans c1, store1 )
        )
        ( qCounts0, a.store )
        solved


qScore : Dict.Dict Int () -> Bool -> QAns -> QAns -> QCounts -> QCounts
qScore allMembers isInternal shadow eager c0 =
    let
        note same acc =
            let
                acc1 =
                    if not isInternal then
                        acc

                    else if same then
                        { acc | internAgree = acc.internAgree + 1 }

                    else
                        { acc | internDiverge = acc.internDiverge + 1 }
            in
            if same || List.length acc1.samples >= 40 then
                acc1

            else
                { acc1
                    | samples =
                        ("QDIV "
                            ++ (if isInternal then
                                    "internal"

                                else
                                    "reaching"
                               )
                            ++ " shadow=["
                            ++ String.join "," (List.map String.fromInt shadow.members)
                            ++ (if shadow.top then
                                    "|TOP"

                                else
                                    ""
                               )
                            ++ "] eager=["
                            ++ String.join "," (List.map String.fromInt eager.members)
                            ++ (if eager.top then
                                    "|TOP"

                                else
                                    ""
                               )
                            ++ "]"
                        )
                            :: acc1.samples
                }

        c =
            c0
    in
    if shadow.top && eager.top then
        note True { c | agree = c.agree + 1 }

    else if shadow.top /= eager.top then
        note False { c | divergeTop = c.divergeTop + 1 }

    else
        case IO.classifySorted shadow.members eager.members of
            Vars.SortedEqual ->
                note True { c | agree = c.agree + 1 }

            Vars.SortedSub ->
                -- shadow ⊊ eager: Q under-records — a write path that is not
                -- instrumented. The defect direction that matters, so it is
                -- split by cause rather than just counted.
                let
                    missing =
                        List.filter (\m -> not (List.member m shadow.members)) eager.members

                    merged =
                        List.all (\m -> Dict.member m allMembers) missing
                in
                if merged then
                    note False { c | divergeSub = c.divergeSub + 1, subMerged = c.subMerged + 1 }

                else
                    note False { c | divergeSub = c.divergeSub + 1, subUnseen = c.subUnseen + 1 }

            Vars.SortedSuper ->
                note False { c | divergeSuper = c.divergeSuper + 1 }

            Vars.SortedMixed ->
                note False { c | divergeOther = c.divergeOther + 1 }


{-| The eager answer for one class, as the STORE holds it: `Nothing` when the
slot is still unconstrained (no answer to compare against), otherwise the raw
least resolution with `LsFrom` edges pulled exactly as `zonkSetSlot` pulls
them — minus the read-time policy, per this module's doc above.
-}
qEagerAt : Maybe Vars.Variable -> IO.State -> ( Maybe QAns, IO.State )
qEagerAt maybeVar store =
    case maybeVar of
        Nothing ->
            ( Nothing, store )

        Just v ->
            qEagerGo Dict.empty v store


qEagerGo : Dict.Dict Int () -> Vars.Variable -> IO.State -> ( Maybe QAns, IO.State )
qEagerGo seen v store0 =
    let
        raw =
            Engine.pointKey v
    in
    if Dict.member raw seen then
        ( Just qBot, store0 )

    else
        let
            ( store1, desc ) =
                UF.get v store0

            seen1 =
                Dict.insert raw () seen
        in
        case desc.content of
            Vars.Structure (Vars.LambdaSet1 (Vars.LsTop _)) ->
                ( Just { top = True, members = [] }, store1 )

            Vars.Structure (Vars.LambdaSet1 (Vars.LsMembers ms)) ->
                ( Just { top = False, members = ms }, store1 )

            Vars.Structure (Vars.LambdaSet1 (Vars.LsFrom ms srcs)) ->
                List.foldl
                    (\src ( accM, stAcc ) ->
                        case accM of
                            Nothing ->
                                ( Nothing, stAcc )

                            Just acc ->
                                if acc.top then
                                    ( Just acc, stAcc )

                                else
                                    let
                                        ( sub, stN ) =
                                            qEagerGo seen1 src stAcc
                                    in
                                    ( Just (qJoin acc (Maybe.withDefault qBot sub)), stN )
                    )
                    ( Just { top = False, members = ms }, store1 )
                    srcs

            _ ->
                ( Nothing, store1 )


{-| LSS\_023: install a deferred inclusion "dst ⊇ src" (both FunL SET SLOTS).
⊤ dst absorbs (skip). Self-edge (UF-equivalent) skips. Total; never fails.
Descriptor-preserving: `UF.set` replaces the WHOLE descriptor at the root, so
this always writes `{ desc | content = … }`, never a fresh descriptor
(the `setRootC` precedent).

Every caller is part of the LSS\_020 signature channel, the kernel-tunnel join
included. That used to be a `lss.sigFlow` obligation — a caller outside the
gate let `LsFrom` escape into a flag-off store and falsified the Phase-A
inertness gate (plan §2.2). The flag was fixed at its default and removed
2026-09-18; the structural claim about who may mint `LsFrom` still holds.

-}
addSlotSource : Vars.Variable -> Vars.Variable -> Engine.S -> Engine.S
addSlotSource src dst s0 =
    case Engine.liftIO (UF.equivalent src dst) s0 of
        ( same, s1 ) ->
            if same then
                s1

            else
                case Engine.liftIO (UF.get dst) s1 of
                    ( desc, s2a ) ->
                        let
                            -- §5.1: an LSS_023 edge IS a constraint — `σ_dst ⊇
                            -- σ_src`. Recording it is what lets the shadow
                            -- solution reproduce a pull-at-read answer, which
                            -- direct member constraints alone cannot.
                            s2 =
                                if qOnFor s2a then
                                    case Engine.liftIO (UF.get src) s2a of
                                        ( srcDesc, s2b ) ->
                                            let
                                                aux =
                                                    s2b.itemAux
                                            in
                                            { s2b | itemAux = { aux | qLog = Engine.QEdge dst src (qPreOf desc) (qPreOf srcDesc) :: aux.qLog } }

                                else
                                    s2a

                            write content sN =
                                case Engine.liftIO (UF.set dst { desc | content = content }) sN of
                                    ( _, sM ) ->
                                        Engine.bumpEdgeInstalled sM
                        in
                        case desc.content of
                            Vars.Structure (Vars.LambdaSet1 (Vars.LsTop _)) ->
                                -- ⊤ ⊇ everything already.
                                s2

                            Vars.FlexVar _ ->
                                write (Vars.Structure (Vars.LambdaSet1 (Vars.LsFrom [] [ src ]))) s2

                            Vars.Structure (Vars.LambdaSet1 (Vars.LsMembers ms)) ->
                                write (Vars.Structure (Vars.LambdaSet1 (Vars.LsFrom ms [ src ]))) s2

                            Vars.Structure (Vars.LambdaSet1 (Vars.LsFrom ms ss)) ->
                                if List.any (\p -> IO.pointKey p == IO.pointKey src) ss then
                                    s2

                                else
                                    write (Vars.Structure (Vars.LambdaSet1 (Vars.LsFrom ms (src :: ss)))) s2

                            _ ->
                                -- Defensive: fail toward ⊤, never toward skip —
                                -- a dropped edge under-approximates (the
                                -- miscompile direction). `needSlow`'s precedent
                                -- defers to a SOUND slow path; ours writes ⊤.
                                write IO.lsTopContent s2


{-| Poison every arrow set slot reachable in a loaded type structure: kernels
apply closures through the generic runtime path, so any arrow crossing the
kernel/port ABI is dynamic (LSS\_004). Point-indexed `seen` set guards against
revisits; store structure is finite.
-}
poisonArrowSets : Vars.Variable -> Engine.S -> Engine.S
poisonArrowSets v0 s0 =
    -- Phase 3: ctx-threaded DFS — one ~6-field ctx copy per visited node and
    -- ONE S write-back here, where the old shape copied the full S record per
    -- visited node.
    foldSetWrites (poisonGoC Dict.empty [ v0 ] (setWriteCtx (qOnFor s0) s0.store)) s0


poisonGoC : Dict.Dict Int () -> List Vars.Variable -> SetWriteCtx -> SetWriteCtx
poisonGoC seen worklist c0 =
    case worklist of
        [] ->
            c0

        v :: rest ->
            let
                key =
                    Engine.pointKey v
            in
            if Dict.member key seen then
                poisonGoC seen rest c0

            else
                let
                    seen1 =
                        Dict.insert key () seen

                    ( _, desc ) =
                        -- The returned state is DROPPED, not threaded. `UF.get`'s only
                        -- write is path compression, and the store is mutated in place
                        -- (step 3), so the compression has already happened; the state it
                        -- hands back differs from `c0.store` in nothing but the record
                        -- wrapper. Threading it cost a context copy per read.
                        UF.get v c0.store

                    c1 =
                        c0
                in
                case desc.content of
                    Vars.Structure flat ->
                        case flat of
                            Vars.FunL a b slot ->
                                -- LSS_004 boundary poison: §4.9 tkPoison.
                                poisonGoC seen1 (a :: b :: rest) (unifySlotWithSetC (Just Mono.tkPoison) [] slot c1)

                            Vars.Fun1 a b ->
                                poisonGoC seen1 (a :: b :: rest) c1

                            Vars.App1 _ _ args ->
                                poisonGoC seen1 (args ++ rest) c1

                            Vars.Record1 fields ext ->
                                poisonGoC seen1 (Dict.values fields ++ (ext :: rest)) c1

                            Vars.Tuple1 a b cs ->
                                poisonGoC seen1 (a :: b :: cs ++ rest) c1

                            Vars.EmptyRecord1 ->
                                poisonGoC seen1 rest c1

                            Vars.Unit1 ->
                                poisonGoC seen1 rest c1

                            Vars.LambdaSet1 _ ->
                                poisonGoC seen1 rest c1

                    Vars.Alias _ _ _ real ->
                        poisonGoC seen1 (real :: rest) c1

                    _ ->
                        -- Variables: nothing reachable to poison.
                        poisonGoC seen1 rest c1



-- ====== ZONK: store Point -> MonoType ======


{-| M6.0-b: bundle-threaded zonk. Reads a Point back to a MonoType (post-order
over union-find content; residuals stamp from live content, ids from `revMemo`).
Threads a 2-field `ZonkCtx` {store, next} (reading superTable/revMemo as args)
internally and writes `S` back ONCE, rather than a full S-copy per node (the
former `liftIO (UF.get var)`). Byte-identical: same UF reads, same residual-id
allocation order threaded through `next`.
-}
type alias ZonkCtx =
    { store : IO.State
    , next : TypeIds.MVarId
    , lssOn : Bool -- lss.enabled. Was read as `lss /= Nothing`; since step 7 the accumulator is report-scoped, so the two are no longer the same question.
    , maxSetSize : Int -- policy (0 = unlimited). Was a field on the accumulator, which is why the accumulator had to exist off report.
    , lss : Maybe LssZonkAcc -- Just iff lss.enabled AND lss.report. Nothing on the default path, so every counter bump is a `case` on a constant and allocates nothing.
    , ecoReads : List Vars.Variable -- MONO_029 stale-read barrier: vars read FREE while producing a CEcoValue residual (folded into S.ecoResidualReads)
    , intern : Intern -- K6: hash-cons table, carried in from S and written back once by `zonkToMono`
    , memberTable : Engine.LssMemberTable -- LSS_019: carried in from S, written back once (zonk grounding interns ground member ids)
    , nextMemberId : Int -- ditto (grounding may allocate fresh member ids)
    , arrowOf : Dict.Dict Int Int -- multi-set census (M3): set-slot pointKey -> ArrowId, carried in from `itemAux.arrowOfSlot`. READ-ONLY here. Empty unless `lss.report`.

    -- PHASE 3 (plans/lss-set-variable.md): the canonical numbering of set
    -- VARIABLES for the type currently being zonked. `pointKey (repr slot) ->
    -- n`, allocated in walk order, RESET per `zonkToMono` call because the
    -- numbering is scoped to one `MonoType`.
    --
    -- This is what gives the paper's α its identity across the annotation
    -- round trip: two arrows the store UNIFIED share a repr, so they get the
    -- SAME n, so `monoTypeToVarC` mints ONE slot for both when the annotation
    -- is re-encoded. Phase 1's anonymous `LUnknown` lost exactly that.
    , varOf : Dict.Dict Int Int
    , nextVar : Int
    }


{-| Hash-cons a freshly built composite against the ctx table (K6). Children are
already canonical (zonk is post-order), so the bucket confirm is O(arity).

The size guard is `Engine.withIntern`'s, for the same reason: this runs once per
composite zonked, and a HIT (~99% of calls, plan §13) must not pay a `ZonkCtx`
copy to store back a table that did not change. Equal counts imply the same
table — `hashCons` either hits and returns its input, or inserts and increments.

-}
consC : Mono.MonoType -> ZonkCtx -> ( Mono.MonoType, ZonkCtx )
consC mt c =
    let
        ( mt1, intern1 ) =
            Intern.hashCons mt c.intern
    in
    -- `entries`, not `size` — see `Engine.withIntern`.
    if Intern.entries intern1 == Intern.entries c.intern then
        ( mt1, c )

    else
        ( mt1, { c | intern = intern1 } )


{-| Set-slot readback accumulator (maxSetSize policy + census counters,
folded back into `S.lssStats` by the `zonkToMono` wrapper).
-}
type alias LssZonkAcc =
    { zonked : Int
    , widenedBySize : Int
    , hist : Dict.Dict Int Int

    -- Phase 1 census (plans/lss-set-write-substrate.md): `hist` is fed only on
    -- the WITHIN-cap branch, so the sizes of sets that widen are thrown away
    -- today — exactly the magnitudes the sorted-list worst case needs.
    , widenedHist : Dict.Dict Int Int

    -- LSS_019 standalone-member grounding (plans/lss-fidelity-2-standalone-member-grounding.md):
    -- the flag gates the whole rewrite (flag-off zonk is allocation-identical
    -- to pre-plan); the counters fold into `lssStats.grounding`.
    , grounded : Int
    , groundingDeferred : Int

    -- LSS_026(a) honest sources (plans/lss-gap2-callarg-transport.md §3.2):
    -- members reached over a DANGLING (FlexVar) source resolve ⊤, never a
    -- set. ESCALATED to unconditional 2026-08-23. Since step 6 the policy is
    -- an ARGUMENT to `resolveSlotMembersWith` rather than a field seeded True
    -- at every production site; the store-level pins (`LssHonestSourcesTest`)
    -- pass False to assert the other direction of the rule.
    -- The escalation trigger was a runtime witness, not the census: the
    -- self-compile measures zero crossings (`mixed|sig` = `mixed|demand` =
    -- 0), but `test/elm/src/LssMixedSigHonestyTest.elm` miscompiles at the
    -- shipping default without the rule — a false `{g|incr}` singleton that
    -- LSS_025's post-settle devirt then trusts. Plan §0.5's own criterion.
    -- `mixedFlexGc` still classifies the crossings: a `gc` member grounds
    -- (LSS_019) and is devirt-consumable, where a lambda id merely declines
    -- (LSS_017).
    , mixedFlex : Int
    , mixedFlexGc : Int

    -- LSS_026 zonk-cause census (plan §2.1 row "zc|"): WHY did each set
    -- slot read back what it read? `censusOn` mirrors `env.lss.report`
    -- (ZonkCtx has no `S`); all six counters stay 0 when it is off, so the
    -- default path pays a Bool test per readback. The consumer attribution
    -- happens at `foldZonkStats` (where `currentGlobal` is in scope) —
    -- within one `zonkToMono` call every readback belongs to one consumer.
    --   causeSet       LsMembers within cap  -> LSet (the win case)
    --   causePoison    explicit LsTop        -> LTop (widened/kernel/demand-encoded)
    --   causeFlex      FlexVar residual      -> LUnknown (nothing ever written — the GAP-2 class)
    --   causeEdgeSet   LsFrom resolved to a set within cap
    --   causeEdgeEmpty LsFrom resolved empty -> LUnknown
    --   causeEdgeTop   LsFrom absorbed by a reachable ⊤ -> LTop
    --   causeUnknown   the LUnknown total = causeFlex + causeEdgeEmpty
    -- (over-cap reads of either arm are already `widenedBySize` — the
    -- seventh cause, not duplicated here.)
    --
    -- Phase 1 (plans/lss-unknown-elimination.md §3.2) keeps the OLD counters
    -- bumped alongside `causeUnknown` on purpose: the `zc|` rows stay joinable
    -- against the pre-split baseline and against
    -- plans/lss-gap2-callarg-transport.md. `causeUnknown` is a strict superset
    -- for the §2.5 ledger. Drop the overlap only after Phase 2 lands.
    --
    -- SUB-HAZARD not to lose: `resolveSlotMembers` returns `Nothing` under
    -- LSS_026(a)'s honest-∅ rule and lands on `causeEdgeTop`, where it is
    -- indistinguishable from a real reachable-⊤ absorb. That IS a genuine
    -- soundness widening so `LTop` is right — but it means the ledger's `top`
    -- bucket silently contains the honest-∅ population. Split it with its own
    -- counter if a phase's measurement comes out ambiguous.
    , causeSet : Int
    , causePoison : Int
    , causeFlex : Int
    , causeEdgeSet : Int
    , causeEdgeEmpty : Int
    , causeEdgeTop : Int
    , causeUnknown : Int

    -- Multi-set census (M3): ArrowId -> the members read back at that arrow,
    -- for |set| >= 2 only. Report-gated (`censusOn`). Folded into
    -- `lssStats.sigStats.multiSetsByArrow` at `foldZonkStats`.
    , multiSets : Dict.Dict Int (List Int)

    -- POST-SETTLE RE-ZONK (plans/lss-post-mono-architecture.md §3.2): the dual
    -- of `multiSets` — ArrowId -> how many readbacks at that arrow came back a
    -- VARIABLE. Report-gated, and (unlike `multiSets`) consumed ONLY by
    -- `rezonkSettled`; `foldZonkStats` deliberately drops the in-flight copy,
    -- because a mid-translation var says nothing — the question is which
    -- arrows are still var once the item has finished writing.
    , varArrows : Dict.Dict Int Int

    -- The universe `varArrows` is scored against: every arrow that read back a
    -- CONCRETE set, of ANY size. It has to be its own table rather than a
    -- reuse of `multiSets`, which is gated at |set| >= 2 — an arrow resolved
    -- to a SINGLETON somewhere else is still "known elsewhere", and scoring it
    -- against the multi-set table alone would misfile it as unconstrained and
    -- overstate the kernel-boundary ceiling.
    , setArrows : Dict.Dict Int Int
    }


{-| LSS\_026 zonk-cause census: bump one cause counter, only under report.
-}
bumpCauseC : (LssZonkAcc -> LssZonkAcc) -> ZonkCtx -> ZonkCtx
bumpCauseC f c =
    case c.lss of
        Just acc ->
            { c | lss = Just (f acc) }

        Nothing ->
            c


zonkToMono : Vars.Variable -> Engine.S -> ( Mono.MonoType, Engine.S )
zonkToMono var s =
    -- Step 10e: A1 explicit trailing-S (was `\s -> …`), so every call is
    -- saturated and the result pair is `$sret`-promotable.
    let
        lssAcc =
            -- Report-scoped since step 7: the accumulator holds COUNTERS
            -- only, so off report there is nothing to accumulate and every
            -- bump becomes a `case` on a constant `Nothing`. The policy
            -- bits it used to carry are `lssOn` / `maxSetSize` on the ctx.
            if s.env.lss.enabled && s.env.lss.report then
                Just { zonked = 0, widenedBySize = 0, hist = Dict.empty, widenedHist = Dict.empty, grounded = 0, groundingDeferred = 0, mixedFlex = 0, mixedFlexGc = 0, causeSet = 0, causePoison = 0, causeFlex = 0, causeEdgeSet = 0, causeEdgeEmpty = 0, causeEdgeTop = 0, causeUnknown = 0, multiSets = Dict.empty, varArrows = Dict.empty, setArrows = Dict.empty }

            else
                Nothing
    in
    case zonkToMonoC s.superTable s.revMemo var { store = s.store, next = s.nextMVarId, lssOn = s.env.lss.enabled, maxSetSize = s.env.lss.maxSetSize, lss = lssAcc, ecoReads = [], intern = s.intern, memberTable = s.lssMemberTable, nextMemberId = s.nextMemberId, arrowOf = s.itemAux.arrowOfSlot, varOf = Dict.empty, nextVar = 0 } of
        ( mt, c ) ->
            let
                s1 =
                    case c.ecoReads of
                        [] ->
                            { s | store = c.store, nextMVarId = c.next, intern = c.intern, lssMemberTable = c.memberTable, nextMemberId = c.nextMemberId }

                        reads ->
                            let
                                aux0 =
                                    s.itemAux
                            in
                            { s | store = c.store, nextMVarId = c.next, intern = c.intern, lssMemberTable = c.memberTable, nextMemberId = c.nextMemberId, itemAux = { aux0 | ecoResidualReads = reads ++ aux0.ecoResidualReads } }

                -- §3.2: log the variable so `rezonkSettled` can replay this
                -- exact readback at `finishNode`. Report-gated, so the
                -- default path pays nothing. `rezonkSettled` calls
                -- `zonkToMonoC` directly and therefore never re-enters here
                -- — the log cannot feed itself.
                s2 =
                    if s.env.lss.report then
                        let
                            aux1 =
                                s1.itemAux
                        in
                        { s1 | itemAux = { aux1 | zonkLog = var :: aux1.zonkLog } }

                    else
                        s1
            in
            ( mt, foldZonkStats c s2 )


{-| POST-SETTLE RE-ZONK (plans/lss-post-mono-architecture.md §3.2, Item 2).

Replay every readback this item made, against the same store, at
`finishNode` — i.e. after the item has finished writing. Accumulate a SECOND
ledger from the results and change nothing else.

READ-ONLY BY CONSTRUCTION, and that is load-bearing: this is a measurement,
and if it wrote back it would be a behaviour change wearing a census's
clothes. `zonkToMonoC` does mutate its `ZonkCtx` — path compression, residual
MVarId stamping, member interning — so the discipline is that the final ctx is
DROPPED entirely and only `ctx.lss` is read. The ctx is still threaded ACROSS
the fold, because sequential zonks share a store in the real run too and the
replay should differ from it in TIME only.

Why this is the right experiment for Eco specifically: `Engine.resetItem`
installs a fresh store per work item, so a set slot read during translation
can only ever be refined by writes landing before that same item finishes.
There is no long-lived store to "settle" into. Replaying at `finishNode` is
therefore not an approximation of the post-mono read — it is the complete
upper bound on what reading later can buy WITHIN the current architecture.
Whatever this does not recover is, by construction, only reachable by a solve
that outlives the item — which is what the plan proposes.

-}
rezonkSettled : Engine.S -> Engine.S
rezonkSettled s =
    if not (s.env.lss.enabled && s.env.lss.report) then
        s

    else
        case s.itemAux.zonkLog of
            [] ->
                s

            log ->
                let
                    acc0 =
                        { zonked = 0, widenedBySize = 0, hist = Dict.empty, widenedHist = Dict.empty, grounded = 0, groundingDeferred = 0, mixedFlex = 0, mixedFlexGc = 0, causeSet = 0, causePoison = 0, causeFlex = 0, causeEdgeSet = 0, causeEdgeEmpty = 0, causeEdgeTop = 0, causeUnknown = 0, multiSets = Dict.empty, varArrows = Dict.empty, setArrows = Dict.empty }

                    -- Same reason as `qCensusInto`: the replay compresses
                    -- paths, and an in-place store would keep those writes.
                    sM =
                        Engine.markStore s

                    ctxN =
                        List.foldl
                            (\v c ->
                                -- `varOf`/`nextVar` are scoped to ONE zonked
                                -- MonoType (they are the Phase-3 variable
                                -- numbering), so they reset per readback
                                -- exactly as `zonkToMono` resets them per call.
                                -- `ecoReads` is cleared too: it is the MONO_029
                                -- stale-read barrier's accumulator, it is
                                -- dropped with the ctx, and letting it grow
                                -- across 400k+ replayed readbacks retains a
                                -- list nothing will ever look at.
                                -- Step 10c/10e: the `Err _ -> c` arm is gone
                                -- with the `Result`. It recovered only the two
                                -- `EngineBug` invariants inside `zonkToMonoC`,
                                -- which the crash policy says abort — and the
                                -- MAIN path would have hit them first, so this
                                -- census could never have been the one to see
                                -- them.
                                case zonkToMonoC s.superTable s.revMemo v { c | varOf = Dict.empty, nextVar = 0, ecoReads = [] } of
                                    ( _, c1 ) ->
                                        c1
                            )
                            { store = sM.store, next = s.nextMVarId, lssOn = s.env.lss.enabled, maxSetSize = s.env.lss.maxSetSize, lss = Just acc0, ecoReads = [], intern = s.intern, memberTable = s.lssMemberTable, nextMemberId = s.nextMemberId, arrowOf = s.itemAux.arrowOfSlot, varOf = Dict.empty, nextVar = 0 }
                            log
                in
                case ctxN.lss of
                    Nothing ->
                        Engine.rollbackStore sM

                    Just acc ->
                        let
                            stats =
                                s.lssStats

                            sig =
                                stats.sigStats

                            prev =
                                sig.settled
                        in
                        -- NOTE what is NOT written: `ctxN.store`, `ctxN.next`,
                        -- `ctxN.intern`, `ctxN.memberTable`, `ctxN.nextMemberId`,
                        -- `ctxN.ecoReads`. Only counters cross this line — and
                        -- the undo scope opened above is closed by rolling it
                        -- back, so the replay's path compression does not
                        -- survive either.
                        Engine.rollbackStore
                            { sM
                                | lssStats =
                                    { stats
                                        | sigStats =
                                            { sig
                                                | settled =
                                                    { items = prev.items + 1
                                                    , zonked = prev.zonked + acc.zonked
                                                    , hist = Dict.foldl (\k v h -> Dict.insert k (v + Maybe.withDefault 0 (Dict.get k h)) h) prev.hist acc.hist
                                                    , widenedBySize = prev.widenedBySize + acc.widenedBySize
                                                    , causeTop = prev.causeTop + acc.causePoison + acc.causeEdgeTop
                                                    , causeVar = prev.causeVar + acc.causeFlex + acc.causeEdgeEmpty
                                                    , varArrows =
                                                        Dict.foldl
                                                            (\akey n tbl -> Dict.insert akey (n + Maybe.withDefault 0 (Dict.get akey tbl)) tbl)
                                                            prev.varArrows
                                                            acc.varArrows
                                                    , setArrows =
                                                        Dict.foldl
                                                            (\akey n tbl -> Dict.insert akey (n + Maybe.withDefault 0 (Dict.get akey tbl)) tbl)
                                                            prev.setArrows
                                                            acc.setArrows
                                                    , scratchDropped = prev.scratchDropped
                                                    }
                                            }
                                    }
                            }


foldZonkStats : ZonkCtx -> Engine.S -> Engine.S
foldZonkStats c s =
    case c.lss of
        Nothing ->
            s

        Just acc ->
            if acc.zonked == 0 && acc.widenedBySize == 0 && acc.mixedFlex == 0 then
                s

            else
                let
                    stats =
                        s.lssStats

                    sig =
                        stats.sigStats
                in
                { s
                    | lssStats =
                        { stats
                            | setsZonked = stats.setsZonked + acc.zonked
                            , widenedBySize = stats.widenedBySize + acc.widenedBySize
                            , sizeHist = Dict.foldl (\k v h -> Dict.insert k (v + Maybe.withDefault 0 (Dict.get k h)) h) stats.sizeHist acc.hist
                            , widenedSizeHist = Dict.foldl (\k v h -> Dict.insert k (v + Maybe.withDefault 0 (Dict.get k h)) h) stats.widenedSizeHist acc.widenedHist
                            , grounding =
                                -- LSS_019 census; the guard keeps flag-off
                                -- (counters permanently 0) allocation-free.
                                if acc.grounded == 0 && acc.groundingDeferred == 0 then
                                    stats.grounding

                                else
                                    { grounded = stats.grounding.grounded + acc.grounded, deferred = stats.grounding.deferred + acc.groundingDeferred }
                            , sigStats =
                                -- LSS_026(a) demand-side mixed resolutions
                                -- (plan §2.1 row 2) + the zonk-cause census
                                -- (row "zc|"). The consumer attribution
                                -- happens HERE because `currentGlobal` is
                                -- only in scope at the fold, not in ZonkCtx;
                                -- every readback of one zonkToMono call
                                -- belongs to one consumer. Cause counters
                                -- are nonzero only under report (censusOn),
                                -- so the default path never touches the dict.
                                let
                                    causesTotal =
                                        -- `causeUnknown` overlaps causeFlex +
                                        -- causeEdgeEmpty today, so it cannot
                                        -- change whether this is zero. Summed
                                        -- anyway so that the day the old
                                        -- counters retire, an item whose ONLY
                                        -- readbacks were unknowns still emits
                                        -- its `zc|<gkey>|…` block instead of
                                        -- vanishing from the census entirely.
                                        acc.causeSet + acc.causePoison + acc.causeFlex + acc.causeEdgeSet + acc.causeEdgeEmpty + acc.causeEdgeTop + acc.causeUnknown
                                in
                                if acc.mixedFlex == 0 && causesTotal == 0 && Dict.isEmpty acc.multiSets then
                                    sig

                                else
                                    { sig
                                        | topMixedFlexDemand = sig.topMixedFlexDemand + acc.mixedFlex

                                        -- M3: union this call's per-arrow
                                        -- multi-sets into the global table.
                                        -- Empty unless report-gated.
                                        , multiSetsByArrow =
                                            Dict.foldl
                                                (\akey ms tbl ->
                                                    Dict.insert akey (unionSortedMembers ms (Maybe.withDefault [] (Dict.get akey tbl))) tbl
                                                )
                                                sig.multiSetsByArrow
                                                acc.multiSets
                                        , argFlowCensus =
                                            let
                                                afterMixed =
                                                    if s.env.lss.report && acc.mixedFlex > 0 then
                                                        bumpCensusKey "mixed|demand"
                                                            acc.mixedFlex
                                                            (bumpCensusKey "mixed|demand|gc" acc.mixedFlexGc sig.argFlowCensus)

                                                    else
                                                        sig.argFlowCensus
                                            in
                                            if causesTotal == 0 then
                                                afterMixed

                                            else
                                                let
                                                    gkey =
                                                        case s.currentGlobal of
                                                            Just g ->
                                                                Mono.toComparableGlobal g

                                                            Nothing ->
                                                                "(none)"
                                                in
                                                afterMixed
                                                    |> bumpCensusKey "zc|all|set" acc.causeSet
                                                    |> bumpCensusKey "zc|all|poison" acc.causePoison
                                                    |> bumpCensusKey "zc|all|flex" acc.causeFlex
                                                    |> bumpCensusKey "zc|all|edgeSet" acc.causeEdgeSet
                                                    |> bumpCensusKey "zc|all|edgeEmpty" acc.causeEdgeEmpty
                                                    |> bumpCensusKey "zc|all|edgeTop" acc.causeEdgeTop
                                                    |> bumpCensusKey "zc|all|unknown" acc.causeUnknown
                                                    |> bumpCensusKey ("zc|" ++ gkey ++ "|set") acc.causeSet
                                                    |> bumpCensusKey ("zc|" ++ gkey ++ "|poison") acc.causePoison
                                                    |> bumpCensusKey ("zc|" ++ gkey ++ "|flex") acc.causeFlex
                                                    |> bumpCensusKey ("zc|" ++ gkey ++ "|edgeSet") acc.causeEdgeSet
                                                    |> bumpCensusKey ("zc|" ++ gkey ++ "|edgeEmpty") acc.causeEdgeEmpty
                                                    |> bumpCensusKey ("zc|" ++ gkey ++ "|edgeTop") acc.causeEdgeTop
                                                    |> bumpCensusKey ("zc|" ++ gkey ++ "|unknown") acc.causeUnknown
                                                    -- M1: the same per-consumer
                                                    -- census, split by SET SIZE
                                                    -- rather than by cause, so a
                                                    -- multi-set can be attributed
                                                    -- to the global that carries
                                                    -- it. `zc|…|set` already gives
                                                    -- the total; these break it up.
                                                    |> (\census0 ->
                                                            Dict.foldl
                                                                (\size n acc2 ->
                                                                    if size < 2 then
                                                                        acc2

                                                                    else
                                                                        acc2
                                                                            |> bumpCensusKey ("zc|all|k" ++ String.fromInt size) n
                                                                            |> bumpCensusKey ("zc|" ++ gkey ++ "|k" ++ String.fromInt size) n
                                                                )
                                                                census0
                                                                acc.hist
                                                       )
                                    }
                        }
                }


{-| LSS\_026 census: add `n` to a key (no-op at `n == 0`, so the flag-off /
report-off path never grows the dict).
-}
bumpCensusKey : String -> Int -> Dict.Dict String Int -> Dict.Dict String Int
bumpCensusKey key n census =
    if n == 0 then
        census

    else
        Dict.insert key (n + Maybe.withDefault 0 (Dict.get key census)) census


zonkToMonoC : Dict.Dict Int Vars.SuperType -> Array (Maybe TypeIds.MVarId) -> Vars.Variable -> ZonkCtx -> ( Mono.MonoType, ZonkCtx )
zonkToMonoC superTable revMemo var c0 =
    let
        ( _, desc ) =
            -- The returned state is DROPPED, not threaded. `UF.get`'s only
            -- write is path compression, and the store is mutated in place
            -- (step 3), so the compression has already happened; the state it
            -- hands back differs from `c0.store` in nothing but the record
            -- wrapper. Threading it cost a context copy per read.
            UF.get var c0.store

        c1 =
            c0
    in
    case desc.content of
        Vars.Structure flat ->
            case zonkFlatC superTable revMemo flat c1 of
                ( zt, zc ) ->
                    ( zt, zc )

        Vars.Alias _ _ _ real ->
            case zonkToMonoC superTable revMemo real c1 of
                ( zt, zc ) ->
                    ( zt, zc )

        Vars.FlexSuper Vars.Number _ ->
            let
                ( mid, c2 ) =
                    residualIdC revMemo var c1
            in
            ( Mono.MVar mid Mono.CNumber, c2 )

        Vars.FlexSuper _ _ ->
            case residualWithTaintC superTable revMemo var c1 of
                ( zt, zc ) ->
                    ( zt, zc )

        Vars.FlexVar _ ->
            case residualWithTaintC superTable revMemo var c1 of
                ( zt, zc ) ->
                    ( zt, zc )

        Vars.RigidVar _ ->
            case residualWithTaintC superTable revMemo var c1 of
                ( zt, zc ) ->
                    ( zt, zc )

        Vars.RigidSuper Vars.Number _ ->
            let
                ( mid, c2 ) =
                    residualIdC revMemo var c1
            in
            ( Mono.MVar mid Mono.CNumber, c2 )

        Vars.RigidSuper _ _ ->
            case residualWithTaintC superTable revMemo var c1 of
                ( zt, zc ) ->
                    ( zt, zc )

        Vars.Error ->
            -- R4: the bottom is wrapped so the leaf is a tuple LITERAL; a bare
            -- call here demotes the whole function off the $sret path.
            ( Engine.crashFailure (EngineBug "Error content encountered in zonkToMono"), c0 )


residualWithTaintC : Dict.Dict Int Vars.SuperType -> Array (Maybe TypeIds.MVarId) -> Vars.Variable -> ZonkCtx -> ( Mono.MonoType, ZonkCtx )
residualWithTaintC superTable revMemo var c0 =
    let
        ( mid, c1 ) =
            residualIdC revMemo var c0
    in
    case Dict.get (Engine.mvarIdKey mid) superTable of
        Just Vars.Number ->
            ( Mono.MVar mid Mono.CNumber, c1 )

        _ ->
            -- MONO_029 stale-read barrier: this zonk is recording an erased
            -- view of a still-free var; if a later unification in the same
            -- item binds it, the recorded output was a stale snapshot. Only
            -- CANONICAL-backed vars (revMemo entry) are tracked: per-call
            -- fresh instantiation vars are read-free-then-bound by design on
            -- EVERY translation pass, so tracking them makes the saturation
            -- loop livelock (found by the R0 census on RecordNarrow tests) —
            -- and they are not the MONO_029 class (nothing else re-reads them).
            case Maybe.andThen identity (Array.get (Engine.pointKey var) revMemo) of
                Just _ ->
                    ( Mono.MVar mid Mono.CEcoValue, { c1 | ecoReads = var :: c1.ecoReads } )

                Nothing ->
                    ( Mono.MVar mid Mono.CEcoValue, c1 )


residualIdC : Array (Maybe TypeIds.MVarId) -> Vars.Variable -> ZonkCtx -> ( TypeIds.MVarId, ZonkCtx )
residualIdC revMemo var c =
    -- A2: point-indexed Array lookup (== the former `Dict.get pk`); a Nothing slot
    -- or out-of-range index means "not recorded" and mints a fresh id.
    case Maybe.andThen identity (Array.get (Engine.pointKey var) revMemo) of
        Just mid ->
            ( mid, c )

        Nothing ->
            ( c.next, { c | next = Id.succ c.next } )


zonkFlatC : Dict.Dict Int Vars.SuperType -> Array (Maybe TypeIds.MVarId) -> Vars.FlatType -> ZonkCtx -> ( Mono.MonoType, ZonkCtx )
zonkFlatC superTable revMemo flat c0 =
    case flat of
        Vars.App1 canonical name args ->
            case zonkListC superTable revMemo args c0 of
                ( mArgs, c1 ) ->
                    case classifyAppC canonical name mArgs c1 of
                        ( zt, zc ) ->
                            ( zt, zc )

        Vars.Fun1 a b ->
            case zonkToMonoC superTable revMemo a c0 of
                ( ma, c1 ) ->
                    case zonkToMonoC superTable revMemo b c1 of
                        ( mb, c2 ) ->
                            case consC (Mono.mFunction Mono.topDeclStoreC [ ma ] mb) c2 of
                                ( zt, zc ) ->
                                    ( zt, zc )

        Vars.FunL a b setVar ->
            case zonkToMonoC superTable revMemo a c0 of
                ( ma, c1 ) ->
                    case zonkToMonoC superTable revMemo b c1 of
                        ( mb, c2 ) ->
                            let
                                ( anno, c3 ) =
                                    zonkSetSlot ma mb setVar c2
                            in
                            case consC (Mono.mFunction anno [ ma ] mb) c3 of
                                ( zt, zc ) ->
                                    ( zt, zc )

        Vars.LambdaSet1 _ ->
            -- LSS_007: a LambdaSet1 only ever lives inside a FunL set slot,
            -- which is consumed by the FunL arm — reaching here is a bug.
            -- R4: wrapped so the leaf is a tuple literal.
            ( Engine.crashFailure (EngineBug "LambdaSet1 outside an arrow slot in zonkFlatC"), c0 )

        Vars.EmptyRecord1 ->
            case consC (Mono.mRecord Dict.empty) c0 of
                ( zt, zc ) ->
                    ( zt, zc )

        Vars.Record1 fields ext ->
            case zonkRecordExtC superTable revMemo ext c0 of
                ( baseFields, c1 ) ->
                    case zonkRecordFieldsC superTable revMemo (Dict.toList fields) baseFields c1 of
                        ( zt, zc ) ->
                            ( zt, zc )

        Vars.Unit1 ->
            ( Mono.MUnit, c0 )

        Vars.Tuple1 a b rest ->
            case zonkToMonoC superTable revMemo a c0 of
                ( ma, c1 ) ->
                    case zonkToMonoC superTable revMemo b c1 of
                        ( mb, c2 ) ->
                            case zonkListC superTable revMemo rest c2 of
                                ( mRest, c3 ) ->
                                    case consC (Mono.mTuple (ma :: mb :: mRest)) c3 of
                                        ( zt, zc ) ->
                                            ( zt, zc )


{-| PHASE 3: the canonical number for this set slot's VARIABLE, within the type
being zonked (`plans/lss-set-variable.md`).

Keyed by the slot's union-find REPRESENTATIVE, which is the whole point: two
arrows the store unified are one variable and must read back the same `n`, so
that re-encoding the annotation (`monoTypeToVarC`) mints ONE slot for both. An
unwritten arrow that shares nothing gets its own fresh `n`.

Numbering is by first encounter in the zonk's walk, which is determined by the
type's structure — so two structurally identical types number identically, and
`LVar n` can safely be part of the comparable key. That is what lets
`(α → α)` and `(α → β)` key DIFFERENTLY while two call sites with the same
sharing pattern key together.

-}
varNumberFor : Vars.Variable -> ZonkCtx -> ( Int, ZonkCtx )
varNumberFor setVar c =
    let
        ( _, reprVar ) =
            UF.repr setVar c.store

        key =
            Engine.pointKey reprVar
    in
    case Dict.get key c.varOf of
        Just n ->
            ( n, c )

        Nothing ->
            ( c.nextVar
            , { c | varOf = Dict.insert key c.nextVar c.varOf, nextVar = c.nextVar + 1 }
            )


{-| Multi-set census (M3): record a `|set| >= 2` readback against the ARROW that
minted this slot, so the report can count distinct arrow POSITIONS rather than
readbacks (plan §2.5.5 — `sizeHist` cannot tell 518 distinct 6-member arrows
from one hot arrow read 518 times).

Report-gated at both ends: the map is empty unless `lss.report`, so an unknown
slot is simply not recorded. Merging is a UNION across readbacks of the same
arrow — one polymorphic def specialized twice reads the same syntactic arrow
twice, and the ARROW is the position being counted.

-}
noteMultiSet : Vars.Variable -> List Int -> ZonkCtx -> ZonkCtx
noteMultiSet setVar members c =
    case c.lss of
        Just acc ->
            if List.length members < 2 then
                c

            else
                let
                    -- The slot that gets ZONKED is often not the slot that was
                    -- MINTED: a loaded arrow and a demand-encoded arrow unify,
                    -- and the surviving `FunL` structure carries whichever
                    -- `pSet` won. Only the LOADED side ever has an ArrowId
                    -- (`monoTypeToVarC` builds from `Mono.MonoType`, which has
                    -- no arrows ids at all), so the lookup must go through the
                    -- union-find class, not the raw Point.
                    ( _, reprVar ) =
                        UF.repr setVar c.store

                    hit =
                        case Dict.get (Engine.pointKey reprVar) c.arrowOf of
                            Just a ->
                                Just a

                            Nothing ->
                                Dict.get (Engine.pointKey setVar) c.arrowOf
                in
                case hit of
                    Nothing ->
                        c

                    Just akey ->
                        { c
                            | lss =
                                Just
                                    { acc
                                        | multiSets =
                                            Dict.insert akey
                                                (unionSortedMembers members (Maybe.withDefault [] (Dict.get akey acc.multiSets)))
                                                acc.multiSets
                                    }
                        }

        Nothing ->
            c


{-| The dual of `noteMultiSet` (plans/lss-post-mono-architecture.md §3.2):
attribute a VARIABLE readback to the arrow whose slot produced it.

Same union-find lookup and the same reason for it — the slot that gets zonked
is often not the slot that was minted, and only the loaded side carries an
ArrowId — so the two censuses key the same arrow the same way and their
keyspaces subtract. That is the whole point: after the item settles,
`varArrows ∩ multiSetsByArrow` is the population that a post-mono solve over
one global graph would resolve and Eco's per-item store cannot, while
`varArrows \ multiSetsByArrow` is unconstrained everywhere and no reordering
reaches it.

-}
noteArrowClass : Bool -> Vars.Variable -> ZonkCtx -> ZonkCtx
noteArrowClass resolved setVar c =
    case c.lss of
        Just acc ->
            let
                ( _, reprVar ) =
                    UF.repr setVar c.store

                hit =
                    case Dict.get (Engine.pointKey reprVar) c.arrowOf of
                        Just a ->
                            Just a

                        Nothing ->
                            Dict.get (Engine.pointKey setVar) c.arrowOf
            in
            case hit of
                Nothing ->
                    c

                Just akey ->
                    { c
                        | lss =
                            Just
                                (if resolved then
                                    { acc | setArrows = Dict.insert akey (1 + Maybe.withDefault 0 (Dict.get akey acc.setArrows)) acc.setArrows }

                                 else
                                    { acc | varArrows = Dict.insert akey (1 + Maybe.withDefault 0 (Dict.get akey acc.varArrows)) acc.varArrows }
                                )
                    }

        Nothing ->
            c


{-| Ascending union of two ascending, deduplicated member lists.
-}
unionSortedMembers : List Int -> List Int -> List Int
unionSortedMembers xs ys =
    case ( xs, ys ) of
        ( [], _ ) ->
            ys

        ( _, [] ) ->
            xs

        ( x :: xr, y :: yr ) ->
            if x == y then
                x :: unionSortedMembers xr yr

            else if x < y then
                x :: unionSortedMembers xr ys

            else
                y :: unionSortedMembers xs yr


{-| Read a set slot back to an annotation. THE only producer of `LSet`. Runs
at item quiescence (zonk is the commit point — MONO\_028 discipline), so a set
is read only after every unification the item will ever do. `paramT`/`resultT`
are the already-zonked param/result of the arrow whose slot this is — the
demanded instantiation LSS\_019's grounding keys on. Policy:

  - unresolved slot (FlexVar) -> LTop (unknown, NOT empty — an empty claim
    would license consumers to treat the arrow as dead)
  - LsTop -> LTop (widened / kernel-facing)
  - LsMembers members -> provisional `g|`/`c|`
    members first ground to `g|<global>|<widened-arrow-typeKey>` when the
    arrow is residual-free (LSS\_019; deferral keeps the provisional id) —
    then LSet members, the store list by pointer (ascending by construction),
    unless |members| > maxSetSize -> LTop (counted in widenedBySize +
    widenedSizeHist; the cap applies to the REWRITTEN list — plan §3.2.3)

Ground ids written back into slots by a demand encode (`monoTypeToVarC`)
pass through the rewrite untouched (not in `provisionalStandalone`), so
zonk∘encode∘zonk is idempotent — the stability LSS\_010's finite-lattice
argument needs.

-}
zonkSetSlot : Mono.MonoType -> Mono.MonoType -> Vars.Variable -> ZonkCtx -> ( Mono.LambdaSetAnno, ZonkCtx )
zonkSetSlot paramT resultT setVar c0 =
    let
        ( _, desc ) =
            -- The returned state is DROPPED, not threaded. `UF.get`'s only
            -- write is path compression, and the store is mutated in place
            -- (step 3), so the compression has already happened; the state it
            -- hands back differs from `c0.store` in nothing but the record
            -- wrapper. Threading it cost a context copy per read.
            UF.get setVar c0.store

        c1 =
            c0
    in
    case desc.content of
        Vars.Structure (Vars.LambdaSet1 (Vars.LsTop tpK)) ->
            -- §4.9: the stored ⊤'s birth kind rides out to the Mono anno
            -- (the `causePoison` counter name is historical — it counts
            -- explicit-⊤ readbacks of every kind).
            ( Mono.topOfKind tpK, bumpCauseC (\a -> { a | causePoison = a.causePoison + 1 }) (bumpZonkAcc Nothing c1) )

        Vars.Structure (Vars.LambdaSet1 (Vars.LsMembers members0)) ->
            if c1.lssOn then
                let
                    ( members, c2 ) =
                        groundMembersC paramT resultT members0 c1

                    size =
                        List.length members
                in
                -- maxSetSize 0 = UNLIMITED (2026-08-29).
                if c1.maxSetSize > 0 && size > c1.maxSetSize then
                    ( Mono.topWiden, bumpWidenedAcc size c2 )

                else
                    -- Phase 2: IDENTITY — the store list IS the LSet
                    -- payload (ascending by construction; was Dict.keys).
                    ( Mono.LSet members, noteArrowClass True setVar (noteMultiSet setVar members (bumpCauseC (\a -> { a | causeSet = a.causeSet + 1 }) (bumpZonkAcc (Just size) c2))) )

            else
                -- A FunL zonked outside an lss-enabled wrapper (e.g. a
                -- direct zonkToMonoC caller): sound fallback.
                ( Mono.topEdge, c1 )

        Vars.Structure (Vars.LambdaSet1 (Vars.LsFrom members0 srcs)) ->
            -- LSS_023 pull-at-read: resolve the reachable edge graph NOW and
            -- read the least fixpoint. Do NOT write the resolved value back —
            -- later reads must re-pull (sources may have grown; collapsing
            -- would freeze them out). This arm sits BEFORE the wildcard so
            -- `LsFrom` is never silently eaten as LTop (sound but
            -- precision-dead — the whole plan's point lost in one arm).
            if c1.lssOn then
                case resolveSlotMembers members0 srcs c1 of
                    ( Nothing, c2 ) ->
                        -- A reachable ⊤ absorbs the whole resolution.
                        ( Mono.topEdge, bumpCauseC (\a -> { a | causeEdgeTop = a.causeEdgeTop + 1 }) (bumpZonkAcc Nothing c2) )

                    ( Just [], c2 ) ->
                        -- EMPTY resolution = NO INFORMATION. Mirrors the
                        -- FlexVar policy ("never empty"): an `LSet []`
                        -- would claim a provably-dead arrow where
                        -- symmetric HEAD reads an unconstrained class as
                        -- unknown.
                        --
                        -- Phase 1: one of the TWO `LUnknown` producers.
                        -- Nothing was ever written anywhere in this slot's
                        -- reachable edge graph — that is an absence, not a
                        -- widening. Both the old counter and `causeUnknown`
                        -- are bumped so the `zc|` rows stay joinable
                        -- against the pre-split baseline.
                        let
                            ( vn, c2v ) =
                                varNumberFor setVar c2
                        in
                        ( Mono.LVar vn
                        , noteArrowClass False
                            setVar
                            (bumpCauseC (\a -> { a | causeEdgeEmpty = a.causeEdgeEmpty + 1, causeUnknown = a.causeUnknown + 1 })
                                (bumpZonkAcc Nothing c2v)
                            )
                        )

                    ( Just ms0, c2 ) ->
                        -- THEN ground (LSS_019), THEN cap — verbatim the
                        -- LsMembers tail on the RESOLVED list (resolution
                        -- precedes grounding: groundMembersC keys on this
                        -- arrow's already-zonked paramT/resultT).
                        let
                            ( members, c3 ) =
                                groundMembersC paramT resultT ms0 c2

                            size =
                                List.length members
                        in
                        if c1.maxSetSize > 0 && size > c1.maxSetSize then
                            ( Mono.topWiden, bumpWidenedAcc size c3 )

                        else
                            ( Mono.LSet members, noteArrowClass True setVar (noteMultiSet setVar members (bumpCauseC (\a -> { a | causeEdgeSet = a.causeEdgeSet + 1 }) (bumpZonkAcc (Just size) c3))) )

            else
                ( Mono.topEdge, c1 )

        _ ->
            -- FlexVar residual: no information — never empty.
            --
            -- Phase 1: the OTHER (and by far the larger) `LUnknown` producer.
            -- The slot was never written by anything, ever — 52.3% of
            -- everything that used to read back as ⊤. Calling that "widened"
            -- made the acceptable share of ⊤ unmeasurable, which is what
            -- plans/lss-unknown-elimination.md Phase 1 exists to fix.
            let
                ( vn, c1v ) =
                    varNumberFor setVar c1
            in
            ( Mono.LVar vn
            , noteArrowClass False
                setVar
                (bumpCauseC (\a -> { a | causeFlex = a.causeFlex + 1, causeUnknown = a.causeUnknown + 1 })
                    (bumpZonkAcc Nothing c1v)
                )
            )


{-| LSS\_023 + LSS\_026: DFS over a slot's deferred-edge graph, returning the
least fixpoint of the inclusion system — `Nothing` when a reachable node is
⊤ (absorbing, short-circuits), else `Just` the ascending union of every
reachable node's members.

LSS\_026(a) — the honest-sources rule. A reached source that is still an
unconstrained `FlexVar` contributes no members, and PRE-LSS\_026 that was
read as exact ("the caller's other edges and members still count"). It is
exact only under write-completeness of every inflow to that source, which
the A.1 arg-load leak violates by construction: an unconnected instantiation
param slot dangles as FlexVar, so a members-carrying resolution over it
claims COMPLETENESS it does not have (`Mono.LSet` is a completeness claim —
plan §0.5). This walk therefore reports whether it crossed such a source,
and `resolveSlotMembers` widens a members-carrying resolution to ⊤ under
the flag. Census-wise the crossing is counted either way, so Phase 0 can
size the exposure before the policy ships.

Discipline (each clause is load-bearing — see the plan §3.1):

  - visited is keyed on the RAW `IO.pointKey` of each source Point (UF
    exposes no root accessor; raw ids are sound and terminating — finitely
    many recorded Points, each visited once; aliased Points re-read
    identical class content and re-unioning is idempotent);
  - marked on ENTRY, before descending — insert-after-descend loops forever
    on edge cycles;
  - the visited set is FRESH per zonkSetSlot call (local, not in ZonkCtx);
  - one-pass DFS union-over-reachables IS the least fixpoint on cycles (a
    visited-hit contributes []; every SCC node's own members are collected
    at that node; ⊤ absorbs);
  - defensive content is treated as ⊤, never as empty — dropping a source's
    contribution under-approximates, the miscompile direction.

-}
resolveSlotMembers : List Int -> List Vars.Variable -> ZonkCtx -> ( Maybe (List Int), ZonkCtx )
resolveSlotMembers members0 srcs c0 =
    -- The honest-sources rule is live exactly when there IS a zonk
    -- accumulator, which is `lss.enabled`. That reproduces the old
    -- `honestSourcesOn` to the letter: it read `acc.honestSources`, seeded
    -- True at every production site, and answered False when the accumulator
    -- was absent. Hardcoding True here would change the lss-off configuration.
    resolveSlotMembersWith (hasLssAcc c0) members0 srcs c0


hasLssAcc : ZonkCtx -> Bool
hasLssAcc c =
    -- Reads `lssOn`, not `lss`: since step 7 the accumulator exists only under
    -- report, while the honesty rule is live whenever LSS is enabled. These
    -- were the same question before and are not any more.
    c.lssOn


{-| `resolveSlotMembers` with the LSS\_026(a) honest-sources rule as an explicit
argument. Production always passes `True` — the rule has been unconditional
since the 2026-08-23 escalation — and the store-level pins pass `False` to
assert the shape the rule exists to reject. It used to be a field on the zonk
accumulator, seeded `True` at every production site.
-}
resolveSlotMembersWith : Bool -> List Int -> List Vars.Variable -> ZonkCtx -> ( Maybe (List Int), ZonkCtx )
resolveSlotMembersWith honest members0 srcs c0 =
    case resolveSources srcs [] False (Just members0) c0 of
        ( Nothing, _, c1 ) ->
            ( Nothing, c1 )

        ( Just ms, sawFlex, c1 ) ->
            if sawFlex && not (List.isEmpty ms) then
                -- LSS_026(a): members PLUS a dangling inflow. The set is
                -- INCOMPLETE but would read as complete — the false-set
                -- (miscompile) direction. `honest` is True in every production
                -- zonk (the rule is UNCONDITIONAL since the 2026-08-23
                -- escalation); the branch survives so the store-level pins can
                -- assert what the pre-rule reader did.
                ( if honest then
                    Nothing

                  else
                    Just ms
                , bumpMixedFlexDemand ms c1
                )

            else
                -- `Just [] + sawFlex` is NOT mixed: the empty-resolution arm
                -- already reads LTop (no completeness claimed), so there is
                -- nothing to widen and nothing to count.
                ( Just ms, c1 )


{-| LSS\_026 census (plan §2.1 row 2, demand side): count a mixed resolution
and the coarsest member class it carries — `gc` members are the ones that
GROUND (LSS\_019) and are consumable by LSS\_025/E9.1 devirt, so they are the
escalation gate. Counters ride the zonk accumulator and fold into
`sigStats` at `zonkToMono`'s exit.
-}
bumpMixedFlexDemand : List Int -> ZonkCtx -> ZonkCtx
bumpMixedFlexDemand members c =
    case c.lss of
        Just acc ->
            { c
                | lss =
                    Just
                        { acc
                            | mixedFlex = acc.mixedFlex + 1
                            , mixedFlexGc =
                                if Engine.membersClass members c.memberTable == "gc" then
                                    acc.mixedFlexGc + 1

                                else
                                    acc.mixedFlexGc
                        }
            }

        Nothing ->
            c


resolveSources : List Vars.Variable -> List Int -> Bool -> Maybe (List Int) -> ZonkCtx -> ( Maybe (List Int), Bool, ZonkCtx )
resolveSources pending visited sawFlex acc c0 =
    case ( pending, acc ) of
        ( _, Nothing ) ->
            ( Nothing, sawFlex, c0 )

        ( [], _ ) ->
            ( acc, sawFlex, c0 )

        ( src :: rest, Just accMembers ) ->
            let
                key =
                    IO.pointKey src
            in
            if List.member key visited then
                resolveSources rest visited sawFlex acc c0

            else
                let
                    ( _, desc ) =
                        -- The returned state is DROPPED, not threaded. `UF.get`'s only
                        -- write is path compression, and the store is mutated in place
                        -- (step 3), so the compression has already happened; the state it
                        -- hands back differs from `c0.store` in nothing but the record
                        -- wrapper. Threading it cost a context copy per read.
                        UF.get src c0.store

                    c1 =
                        c0

                    visited1 =
                        key :: visited
                in
                case desc.content of
                    Vars.Structure (Vars.LambdaSet1 (Vars.LsTop _)) ->
                        ( Nothing, sawFlex, c1 )

                    Vars.Structure (Vars.LambdaSet1 (Vars.LsMembers ms)) ->
                        resolveSources rest visited1 sawFlex (Just (IO.unionSortedAsc accMembers ms)) c1

                    Vars.Structure (Vars.LambdaSet1 (Vars.LsFrom ms ss)) ->
                        resolveSources (ss ++ rest) visited1 sawFlex (Just (IO.unionSortedAsc accMembers ms)) c1

                    Vars.FlexVar _ ->
                        -- LSS_026(a): an unconstrained source contributes no
                        -- members NOW, but it is an UNTRACKED inflow — the
                        -- pre-LSS_026 reading of this as exact holds only
                        -- under write-completeness, which A.1's unconnected
                        -- instantiation params violate. Record the crossing;
                        -- `resolveSlotMembers` applies the policy.
                        resolveSources rest visited1 True acc c1

                    _ ->
                        -- Defensive: unknown content fails toward ⊤.
                        ( Nothing, sawFlex, c1 )


{-| LSS\_019: run the grounding rewrite against the ctx-threaded member table,
folding the census riders into the accumulator. The no-event fast path
returns the ctx UNCHANGED (no copy).
-}
groundMembersC : Mono.MonoType -> Mono.MonoType -> List Int -> ZonkCtx -> ( List Int, ZonkCtx )
groundMembersC paramT resultT members0 c =
    let
        r =
            Engine.groundSetMembers paramT resultT members0 c.memberTable c.nextMemberId
    in
    if r.grounded == 0 && r.deferred == 0 then
        ( members0, c )

    else
        ( r.members
        , { c
            | memberTable = r.table
            , nextMemberId = r.nextId
            , lss =
                Maybe.map
                    (\acc -> { acc | grounded = acc.grounded + r.grounded, groundingDeferred = acc.groundingDeferred + r.deferred })
                    c.lss
          }
        )


{-| The over-cap widening bump (factored from the LsMembers arm; identical
counters).
-}
bumpWidenedAcc : Int -> ZonkCtx -> ZonkCtx
bumpWidenedAcc size c =
    case c.lss of
        Nothing ->
            c

        Just acc ->
            { c
                | lss =
                    Just
                        { acc
                            | zonked = acc.zonked + 1
                            , widenedBySize = acc.widenedBySize + 1
                            , widenedHist = Dict.insert size (1 + Maybe.withDefault 0 (Dict.get size acc.widenedHist)) acc.widenedHist
                        }
            }


bumpZonkAcc : Maybe Int -> ZonkCtx -> ZonkCtx
bumpZonkAcc maybeSize c =
    case c.lss of
        Nothing ->
            c

        Just acc ->
            case maybeSize of
                Nothing ->
                    { c | lss = Just { acc | zonked = acc.zonked + 1 } }

                Just size ->
                    { c | lss = Just { acc | zonked = acc.zonked + 1, hist = Dict.insert size (1 + Maybe.withDefault 0 (Dict.get size acc.hist)) acc.hist } }


zonkListC : Dict.Dict Int Vars.SuperType -> Array (Maybe TypeIds.MVarId) -> List Vars.Variable -> ZonkCtx -> ( List Mono.MonoType, ZonkCtx )
zonkListC superTable revMemo vars c0 =
    case vars of
        [] ->
            ( [], c0 )

        v :: rest ->
            case zonkToMonoC superTable revMemo v c0 of
                ( m, c1 ) ->
                    case zonkListC superTable revMemo rest c1 of
                        ( ms, c2 ) ->
                            ( m :: ms, c2 )


zonkRecordFieldsC : Dict.Dict Int Vars.SuperType -> Array (Maybe TypeIds.MVarId) -> List ( String, Vars.Variable ) -> Dict.Dict String Mono.MonoType -> ZonkCtx -> ( Mono.MonoType, ZonkCtx )
zonkRecordFieldsC superTable revMemo fields base c0 =
    case fields of
        [] ->
            case consC (Mono.mRecord base) c0 of
                ( zt, zc ) ->
                    ( zt, zc )

        ( k, p ) :: rest ->
            case zonkToMonoC superTable revMemo p c0 of
                ( v, c1 ) ->
                    case zonkRecordFieldsC superTable revMemo rest (Dict.insert k v base) c1 of
                        ( zt, zc ) ->
                            ( zt, zc )


{-| Extract the base-field dict from a record extension tail.
-}
zonkRecordExtC : Dict.Dict Int Vars.SuperType -> Array (Maybe TypeIds.MVarId) -> Vars.Variable -> ZonkCtx -> ( Dict.Dict String Mono.MonoType, ZonkCtx )
zonkRecordExtC superTable revMemo ext c0 =
    case zonkToMonoC superTable revMemo ext c0 of
        ( mt, c1 ) ->
            case mt of
                Mono.MRecord _ fields ->
                    ( fields, c1 )

                _ ->
                    -- Open extension resolved to a var/other: no base fields.
                    ( Dict.empty, c1 )


{-| `classifyApp` hash-consed against a `ZonkCtx` (K6). Leaves (`MInt`, …) fall
through `Intern.hashCons` untouched, so this costs one branch on the primitive
arms.
-}
classifyAppC : ModuleName.Canonical -> String -> List Mono.MonoType -> ZonkCtx -> ( Mono.MonoType, ZonkCtx )
classifyAppC canonical name args c =
    consC (classifyApp canonical name args) c


classifyApp : ModuleName.Canonical -> String -> List Mono.MonoType -> Mono.MonoType
classifyApp canonical name args =
    let
        isElmCore =
            case canonical of
                ModuleName.Canonical ( "elm", "core" ) _ ->
                    True

                _ ->
                    False
    in
    if isElmCore then
        case name of
            "Int" ->
                Mono.MInt

            "Float" ->
                Mono.MFloat

            "Bool" ->
                Mono.MBool

            "Char" ->
                Mono.MChar

            "String" ->
                Mono.MString

            "List" ->
                case args of
                    [ inner ] ->
                        Mono.mList inner

                    _ ->
                        Mono.mList Mono.MUnit

            _ ->
                Mono.mCustom canonical name args

    else
        Mono.mCustom canonical name args



-- residual classification (taint + id allocation) now lives in the
-- bundle-threaded `residualWithTaintC`/`residualIdC` above (M6.0-b); the
-- `M1 classifyDirect` miss path uses `residualForVar` directly.
-- ====== CLASSIFY DIRECT: Can.Type -> MonoType without minting store structure ======


{-| Read-only classification of a canonical type into a MonoType. This is the
fast replacement for `zonkToMono ∘ loadType` at classification-only sites
(`Translate.classify`): structure is classified purely (no fresh Points, no `S`
copies), and only a type VARIABLE touches the store — and only to READ:

  - alias-substitution hit → that MonoType (Holey-alias parameter);
  - item-memo hit → the var was concretized by demand this item; zonk the bound
    Point back, exactly as the old path would (this is the only branch that
    threads `S`, since `zonkToMono` may allocate a fresh residual id);
  - miss → the var is unbound this item; stamp its own id with the super from
    the table (see `residualForVar`).

Byte-identical to `zonkToMono ∘ loadType`: the old path mints one anonymous
Point per structural node purely to read it straight back (never memoized, so
nothing downstream can observe it), and mints a var's Point via `loadVar`
recording the var's own id in `revMemo` — so its `residualId` equals the id
`residualForVar` stamps directly. Deferring a miss-var's mint to its first real
store use changes only the internal Point index (never reflected in the output
MonoType), and cannot affect the Number-taint harvest (a classify-only var never
unifies, so it can only ever carry its static super, which `superTable` already
holds from `initState`).

-}
classifyDirect : Int -> Can.Type TypeIds.MVarId -> Engine.S -> ( Mono.MonoType, Engine.S )
classifyDirect topKind canType s =
    -- Step 10b, R4: RE-TUPLE. A bare call in leaf position is only admitted by
    -- the FRESH fixpoint, which is a LEAST fixpoint over an already-admitted
    -- table — so a call leaf into a mutually recursive partner
    -- (`classifyGo` <-> `classifyAliasPlain`) can never bootstrap. Destructuring
    -- and re-tupling turns the leaf into a LET-POSITION call plus a tuple
    -- LITERAL, which `sretTailOk` admits directly. The make-form dissolves
    -- under SROA, so this costs nothing at runtime.
    case classifyGo topKind s Dict.empty canType of
        ( t, s1 ) ->
            ( t, s1 )


classifyGo : Int -> Engine.S -> Dict.Dict Int Mono.MonoType -> Can.Type TypeIds.MVarId -> ( Mono.MonoType, Engine.S )
classifyGo topKind s aliasSubst canType =
    case canType of
        Can.TVar mvarId ->
            let
                key =
                    Engine.mvarIdKey mvarId
            in
            case Dict.get key aliasSubst of
                Just mono ->
                    ( mono, s )

                Nothing ->
                    case Dict.get key s.memo of
                        Just pt ->
                            -- Demand-concretized this item: read the bound Point back.
                            -- Threads S (zonk can allocate a residual id).
                            --
                            -- Step 10b: `zonkToMono` is still `Step`-typed, so its
                            -- result is destructured and RE-TUPLED as a literal here.
                            -- `-> r` on the tuple-typed result would silently demote
                            -- this whole function off the $sret path (R4).
                            -- Step 10e: `zonkToMono` is direct now; the
                            -- re-tuple stays (R4 — a bare call leaf would
                            -- demote `classifyGo` off the $sret path).
                            case zonkToMono pt s of
                                ( mono, sZ ) ->
                                    ( mono, sZ )

                        Nothing ->
                            case residualForVar mvarId s of
                                Mono.MVar _ Mono.CEcoValue ->
                                    -- MONO_029 stale-read barrier: an erased view of
                                    -- a var that has not entered the store yet; if a
                                    -- later loadType mints+binds it, the recorded
                                    -- output was a stale snapshot.
                                    let
                                        aux0 =
                                            s.itemAux
                                    in
                                    ( Mono.MVar mvarId Mono.CEcoValue, { s | itemAux = { aux0 | ecoResidualKeyReads = key :: aux0.ecoResidualKeyReads } } )

                                residual ->
                                    ( residual, s )

        Can.TLambda _ from to ->
            case classifyGo topKind s aliasSubst from of
                ( mFrom, s1 ) ->
                    case classifyGo topKind s1 aliasSubst to of
                        ( mTo, s2 ) ->
                            -- One arrow per MFunction, mirroring zonkFlat's Fun1 arm
                            -- (GlobalOpt flattens later per GOPT_016). Storeless
                            -- classification stamps LTop (sound-but-imprecise;
                            -- fast paths gate on signature triviality in M2).
                            case Engine.consS (Mono.mFunction (Mono.topOfKind topKind) [ mFrom ] mTo) s2 of
                                ( t, s3 ) ->
                                    ( t, s3 )

        Can.TType canonical name args ->
            case classifyList topKind s aliasSubst args of
                ( mArgs, s1 ) ->
                    case Engine.consS (classifyApp canonical name mArgs) s1 of
                        ( t, s2 ) ->
                            ( t, s2 )

        Can.TRecord fields maybeExtension ->
            case classifyRecordExt topKind s aliasSubst maybeExtension of
                ( baseFields, s1 ) ->
                    case classifyRecordFields topKind s1 aliasSubst (Dict.toList fields) baseFields of
                        ( allFields, s2 ) ->
                            case Engine.consS (Mono.mRecord allFields) s2 of
                                ( t, s3 ) ->
                                    ( t, s3 )

        Can.TUnit ->
            ( Mono.MUnit, s )

        Can.TTuple a b rest ->
            case classifyGo topKind s aliasSubst a of
                ( ma, s1 ) ->
                    case classifyGo topKind s1 aliasSubst b of
                        ( mb, s2 ) ->
                            case classifyList topKind s2 aliasSubst rest of
                                ( mRest, s3 ) ->
                                    case Engine.consS (Mono.mTuple (ma :: mb :: mRest)) s3 of
                                        ( t, s4 ) ->
                                            ( t, s4 )

        Can.TAlias home name args aliasType ->
            -- Step 4b: an alias instantiation whose arguments and body are ground and
            -- arrow-free classifies to the same canonical `MonoType` at every
            -- occurrence in the run, so the first classify is cached and every later
            -- one is a hash lookup instead of a node-by-node walk with an intern probe
            -- per node. `S` — the compiler's own 31-field state record — is the case
            -- this exists for.
            --
            -- Exactness: the stored value came out of `consS`, so it IS the intern
            -- table's canonical object, and the table is seeded empty and only grows;
            -- a later probe of the same structure would hand back the very same
            -- object, so returning it without probing is indistinguishable. `topKind`
            -- and `aliasSubst` cannot matter on a hit: the first is read only by the
            -- `TLambda` arm and the second only by the `TVar` arm, and an eligible
            -- instantiation reaches neither.
            case aliasKeyOf home name args of
                Nothing ->
                    case classifyAliasPlain topKind s aliasSubst args aliasType of
                        ( t, s1 ) ->
                            ( t, s1 )

                Just key ->
                    case HashMap.get Engine.aliasKeyHash Engine.aliasKeyEq key s.monoMemo.aliasMemo of
                        Just (Engine.AliasGround mono) ->
                            ( mono, s )

                        Just Engine.AliasIneligible ->
                            case classifyAliasPlain topKind s aliasSubst args aliasType of
                                ( t, s1 ) ->
                                    ( t, s1 )

                        Nothing ->
                            if aliasBodyEligible aliasType then
                                case classifyAliasPlain topKind s aliasSubst args aliasType of
                                    ( mono, s1 ) ->
                                        ( mono, Engine.putAliasVerdict key (Engine.AliasGround mono) s1 )

                            else
                                -- Record the ineligibility too, so a body walk is paid
                                -- once per instantiation rather than once per
                                -- occurrence.
                                case classifyAliasPlain topKind (Engine.putAliasVerdict key Engine.AliasIneligible s) aliasSubst args aliasType of
                                    ( t, s1 ) ->
                                        ( t, s1 )


{-| The two alias arms as they were before step 4b.
-}
classifyAliasPlain : Int -> Engine.S -> Dict.Dict Int Mono.MonoType -> List ( TypeIds.MVarId, Can.Type TypeIds.MVarId ) -> Can.AliasType TypeIds.MVarId -> ( Mono.MonoType, Engine.S )
classifyAliasPlain topKind s aliasSubst args aliasType =
    case aliasType of
        Can.Filled inner ->
            case classifyGo topKind s aliasSubst inner of
                ( t, s1 ) ->
                    ( t, s1 )

        Can.Holey inner ->
            -- Alias args are classified in the OUTER scope (mirrors
            -- Zonk.canTypeToMonoWith's Holey arm), then the body under the extended
            -- substitution.
            case classifyAliasArgs topKind s aliasSubst args aliasSubst of
                ( newSubst, s1 ) ->
                    case classifyGo topKind s1 newSubst inner of
                        ( t, s2 ) ->
                            ( t, s2 )



-- ====== STEP 4: GROUND, ARROW-FREE ALIAS SUBTREES ======


{-| `Mono.mixHash` is not exported, so this is its twin. Same constants, so a hash
computed here is comparable with one computed there (nothing relies on that today; it
is stated so a future reader does not assume they may diverge).
-}
mix : Int -> Int -> Int
mix h x =
    modBy 67108864 (h * 33 + modBy 67108864 x + 7)


{-| `-1` when the type has a free var, an arrow or an open record ANYWHERE; otherwise
a structural hash in `[0, 2^26)`.

Names are hashed through `Eco.Hash.string`, the NARROW kernel variant, for two
reasons. Its range is `[0, 2^26)`, so the `-1` sentinel stays distinguishable and
the four `h < 0` tests below keep working — the wide `string64` can go negative
and would silently poison them. And it is allocation-free and gc-leaf, which is
what makes hashing the characters affordable at all: this used to hash only
`String.length`, so every type in a module whose name was the same length
collided (`Dict`/`Set`, `Task`/`Time`), and the same for record field keys.

One walk, exiting at the first disqualifier, so the common "not eligible" answer is
cheap. Through a `Filled` alias only `inner` is examined, because that is what load and
classify consume; through a `Holey` alias the ARGS are hashed and the body is only
checked for arrow-freeness, because its vars are the alias's parameters and the args
are what distinguish two instantiations.

-}
groundHash : Can.Type TypeIds.MVarId -> Int
groundHash t =
    case t of
        Can.TVar _ ->
            -1

        Can.TLambda _ _ _ ->
            -1

        Can.TUnit ->
            1

        Can.TType (ModuleName.Canonical _ modName) name args ->
            groundHashList (mix (mix (mix 2 (Eco.Hash.string modName)) (Eco.Hash.string name)) (List.length args)) args

        Can.TTuple a b rest ->
            groundHashList (mix 3 (List.length rest)) (a :: b :: rest)

        Can.TRecord _ (Just _) ->
            -1

        Can.TRecord fields Nothing ->
            -- `Dict.foldl` cannot break, so a negative accumulator is sticky: one
            -- compare per remaining field, no further walking.
            Dict.foldl
                (\k (Can.FieldType _ ft) h ->
                    if h < 0 then
                        h

                    else
                        let
                            hf =
                                groundHash ft
                        in
                        if hf < 0 then
                            -1

                        else
                            mix (mix h (Eco.Hash.string k)) hf
                )
                (mix 4 (Dict.size fields))
                fields

        Can.TAlias _ _ _ (Can.Filled inner) ->
            groundHash inner

        Can.TAlias (ModuleName.Canonical _ modName) name args (Can.Holey inner) ->
            let
                h =
                    groundHashList (mix (mix 5 (Eco.Hash.string modName)) (Eco.Hash.string name)) (List.map Tuple.second args)
            in
            if h < 0 || not (noArrowBody inner) then
                -1

            else
                h


groundHashList : Int -> List (Can.Type TypeIds.MVarId) -> Int
groundHashList h ts =
    case ts of
        [] ->
            h

        t :: rest ->
            let
                ht =
                    groundHash t
            in
            if ht < 0 then
                -1

            else
                groundHashList (mix h ht) rest


{-| Arrow-freeness of an alias BODY. Vars are fine here — they are the alias's
parameters — and so is an open extension, which is a parameter too.
-}
noArrowBody : Can.Type TypeIds.MVarId -> Bool
noArrowBody t =
    case t of
        Can.TVar _ ->
            True

        Can.TLambda _ _ _ ->
            False

        Can.TUnit ->
            True

        Can.TType _ _ args ->
            List.all noArrowBody args

        Can.TTuple a b rest ->
            noArrowBody a && noArrowBody b && List.all noArrowBody rest

        Can.TRecord fields _ ->
            Dict.foldl (\_ (Can.FieldType _ ft) ok -> ok && noArrowBody ft) True fields

        Can.TAlias _ _ _ (Can.Filled inner) ->
            noArrowBody inner

        Can.TAlias _ _ args (Can.Holey inner) ->
            List.all (\( _, at ) -> noArrowBody at) args && noArrowBody inner


{-| Ground and arrow-free: no free var, no arrow, no open record.
-}
groundNoArrow : Can.Type TypeIds.MVarId -> Bool
groundNoArrow t =
    groundHash t >= 0


{-| The memo key of an alias occurrence, or `Nothing` when an ARGUMENT disqualifies it.

Looks at the arguments only, never the body, so a probe never pays for a body walk;
whether the BODY is eligible is a separate question answered once per instantiation by
`aliasBodyEligible` and then cached.

-}
aliasKeyOf : ModuleName.Canonical -> String -> List ( TypeIds.MVarId, Can.Type TypeIds.MVarId ) -> Maybe Engine.AliasKey
aliasKeyOf ((ModuleName.Canonical ( author, project ) modName) as home) name args =
    let
        argTypes =
            List.map Tuple.second args

        h0 =
            mix (mix (mix (mix 6 (String.length author)) (String.length project)) (String.length modName))
                (Eco.Hash.string name)

        h =
            groundHashList h0 argTypes
    in
    if h < 0 then
        Nothing

    else
        Just { hash = h, home = home, name = name, args = argTypes }


{-| Is the alias BODY eligible — the part `aliasKeyOf` deliberately did not look at?
-}
aliasBodyEligible : Can.AliasType TypeIds.MVarId -> Bool
aliasBodyEligible aliasType =
    case aliasType of
        Can.Filled inner ->
            groundHash inner >= 0

        Can.Holey inner ->
            noArrowBody inner


{-| `groundNoArrow` that answers an alias occurrence from the run's verdict map when it
can — O(1) for `S`, `Env` and `ItemAux` after their first classify — and walks
otherwise. Step 9 consumes this.
-}
groundNoArrowWith : HashMap.HashMap Engine.AliasKey Engine.AliasVerdict -> Can.Type TypeIds.MVarId -> Bool
groundNoArrowWith aliasMemo t =
    case t of
        Can.TAlias home name args aliasType ->
            case aliasKeyOf home name args of
                Nothing ->
                    False

                Just key ->
                    case HashMap.get Engine.aliasKeyHash Engine.aliasKeyEq key aliasMemo of
                        Just (Engine.AliasGround _) ->
                            True

                        Just Engine.AliasIneligible ->
                            False

                        Nothing ->
                            aliasBodyEligible aliasType

        Can.TType _ _ args ->
            List.all (groundNoArrowWith aliasMemo) args

        Can.TTuple a b rest ->
            groundNoArrowWith aliasMemo a && groundNoArrowWith aliasMemo b && List.all (groundNoArrowWith aliasMemo) rest

        Can.TRecord fields Nothing ->
            Dict.foldl (\_ (Can.FieldType _ ft) ok -> ok && groundNoArrowWith aliasMemo ft) True fields

        Can.TRecord _ (Just _) ->
            False

        Can.TUnit ->
            True

        Can.TVar _ ->
            False

        Can.TLambda _ _ _ ->
            False


classifyList : Int -> Engine.S -> Dict.Dict Int Mono.MonoType -> List (Can.Type TypeIds.MVarId) -> ( List Mono.MonoType, Engine.S )
classifyList topKind s aliasSubst types =
    case types of
        [] ->
            ( [], s )

        t :: rest ->
            case classifyGo topKind s aliasSubst t of
                ( m, s1 ) ->
                    case classifyList topKind s1 aliasSubst rest of
                        ( ms, s2 ) ->
                            ( m :: ms, s2 )


classifyAliasArgs : Int -> Engine.S -> Dict.Dict Int Mono.MonoType -> List ( TypeIds.MVarId, Can.Type TypeIds.MVarId ) -> Dict.Dict Int Mono.MonoType -> ( Dict.Dict Int Mono.MonoType, Engine.S )
classifyAliasArgs topKind s outerSubst args acc =
    case args of
        [] ->
            ( acc, s )

        ( paramId, t ) :: rest ->
            case classifyGo topKind s outerSubst t of
                ( mt, s1 ) ->
                    classifyAliasArgs topKind s1 outerSubst rest (Dict.insert (Engine.mvarIdKey paramId) mt acc)


classifyRecordExt : Int -> Engine.S -> Dict.Dict Int Mono.MonoType -> Maybe TypeIds.MVarId -> ( Dict.Dict String Mono.MonoType, Engine.S )
classifyRecordExt topKind s aliasSubst maybeExtension =
    case maybeExtension of
        Nothing ->
            ( Dict.empty, s )

        Just extVar ->
            case classifyGo topKind s aliasSubst (Can.TVar extVar) of
                ( mt, s1 ) ->
                    case mt of
                        Mono.MRecord _ baseFields ->
                            ( baseFields, s1 )

                        _ ->
                            -- Open extension resolved to a var/other: no base fields
                            -- (matches zonkRecordExt).
                            ( Dict.empty, s1 )


classifyRecordFields : Int -> Engine.S -> Dict.Dict Int Mono.MonoType -> List ( String, Can.FieldType TypeIds.MVarId ) -> Dict.Dict String Mono.MonoType -> ( Dict.Dict String Mono.MonoType, Engine.S )
classifyRecordFields topKind s aliasSubst fields base =
    case fields of
        [] ->
            ( base, s )

        ( k, Can.FieldType _ t ) :: rest ->
            case classifyGo topKind s aliasSubst t of
                ( mt, s1 ) ->
                    classifyRecordFields topKind s1 aliasSubst rest (Dict.insert k mt base)


{-| The residual for a memo-miss var: `MVar id CNumber` if the (static ∪
harvested) super table marks it a `Number`, else `MVar id CEcoValue`. This is
exactly the composite of `loadVar`'s mint (from `superStatic`) and the old zonk
(`FlexSuper Number → CNumber` directly, else `residualWithTaint` over
`superTable`): since `superStatic ⊆ superTable` and both carry `Number`
identically for these vars, one `superTable` lookup reproduces both branches.
-}
residualForVar : TypeIds.MVarId -> Engine.S -> Mono.MonoType
residualForVar mvarId s =
    case Dict.get (Engine.mvarIdKey mvarId) s.superTable of
        Just Vars.Number ->
            Mono.MVar mvarId Mono.CNumber

        _ ->
            Mono.MVar mvarId Mono.CEcoValue
