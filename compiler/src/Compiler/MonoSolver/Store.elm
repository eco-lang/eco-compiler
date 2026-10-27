module Compiler.MonoSolver.Store exposing
    ( loadType, unifyStep, zonkToMono
    , rezonkSettled
    , LoadCtx, LssZonkAcc, SetWriteCtx, ZonkCtx, addSlotSource, aliasBodyEligible, aliasKeyOf, arrowParts, arrowSetSlot, classifyDirect, foldSetWrites, groundHash, groundNoArrow, groundNoArrowWith, loadTypeC, loadTypeIsolated, loadTypeIsolatedWithArrows, loadTypeS, loadTypeWithArrows, monoTypeToVarS, poisonArrowSets, qInferenceCensus, qOnFor, qShadowCensus, resolveSlotMembers, resolveSlotMembersWith, setWriteCtx, testLoadCtx, unifyBestEffortStoreS, unifySlotWithSet, unifySlotWithSetC, unifyStrict, unifyStrictS
    )

{-| The solver engine specializes a definition by unifying types in a union-find
store, and this module is where that store meets the compiler's two type
languages: canonical types (`Can.Type MVarId`) and monomorphic types
(`Mono.MonoType`).

A _Point_ is one union-find variable in the store. Its content is a type
structure, a type variable (flexible or rigid, and possibly constrained to a
super class such as `number`), or the content of a lambda set. The engine gives
each work item a store of its own (`Engine.resetItem`), so every Point, and
every memo that names Points, belongs to the current item only.

The module does five things with the store.

_Load_ turns a canonical type into Points. Every occurrence of a type variable
maps through the item's memo to one Point, within one load and across the item's
shared loads, so unifying any occurrence with a concrete type concretizes all of
them. Loading `number -> number -> number` and unifying one argument with `Int`
makes the whole type `Int -> Int -> Int`; this is how a demanded type propagates
through a definition. An _isolated_ load starts from an empty memo instead and
so gives a fresh instantiation, as for one call site of a polymorphic function.

_Encode_ turns a demanded `MonoType` into fresh Points, which can then be
unified with a loaded type.

_Unify_ merges two Points, using the type checker's own `Compiler.Type.Unify`.
The store is an immutable value, so a caller that wants to undo a failed attempt
keeps the store it had before and puts it back.

_Zonk_ reads a Point back as a `MonoType`. A type variable that is still
unresolved is a _residual_ and reads back as `MVar id CNumber` or `MVar id
CEcoValue`; zonk never chooses a default type for it.

_Classify_ (`classifyDirect`) turns a canonical type straight into a `MonoType`,
reading the store only for the type variables the item has bound.

Under lambda-set specialization (LSS, on when `env.lss.enabled`) every arrow a
load or an encoding mints has a third Point, its _set slot_ (other arrows in the
store may be `Fun1`, with no slot), which holds the arrow's _lambda set_: the
member ids of the function values that can reach the arrow. A slot is unwritten
(a bare flexible variable), ⊤ (anything may reach the arrow; a ⊤ carries a
provenance code, its _kind_), an ascending member list, or members plus
_deferred edges_ from other slots, which are followed when the slot is read.
Writing ⊤ into every slot reachable from a type is _poisoning_. On readback a
slot becomes `LSet` only when its member list is known to be complete: an
unwritten slot, or one whose edges reach no members, becomes a set variable
`LVar n`, and a set that may be incomplete becomes `LTop`. The order in which
a load passes arrows, each contributing its slot whether minted or reused from
the arrow memo, defines the _arrow ordinals_ that signature facts are indexed
by.

Much of the rest of the file is census code gated on `lss.report` or
`lss.qCensus`: counters added to `lssStats` that describe how lambda sets were
written and read, and two replays (`rezonkSettled`, and `qShadowCensus` with
`qInferenceCensus`) that discard the store they produce and keep only counters.

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


{-| The state a load threads in place of the whole engine state `S`: the store,
the item's variable memo and reverse memo, and the per-item tables a load reads
and extends. The load entries build one from `S` and write it back once.

`memo` maps a type variable's `MVarId` key to its Point. `revMemo` is indexed by
Point key and holds the first `MVarId` that minted each Point, which zonk uses
to name a residual. An arrow is identified, in `arrowMemo` and `arrowOfSlot`, by
the key of its `Arrow` id plus one.

-}
type alias LoadCtx =
    { store : IO.State
    , memo : Dict.Dict Int Vars.Variable
    , revMemo : Array (Maybe TypeIds.MVarId)
    , lssOn : Bool -- mint `FunL` arrows with set slots
    , arrowSlots : List Vars.Variable -- reverse order of the arrows passed; a memo hit repeats a slot
    , slotsMinted : Int -- fresh set slots only, not memo hits
    , arrowMemo : Dict.Dict Int Vars.Variable -- arrow key -> its set slot, never the arrow node
    , censusOn : Bool -- `lss.report`; gates `arrowOfSlot` only
    , arrowOfSlot : Dict.Dict Int Int -- set slot Point key -> arrow key, for the census
    , groundLoads : HashMap.HashMap Engine.AliasKey Vars.FlatType -- ground alias instantiation -> root content of its first load in this store
    , aliasMemo : HashMap.HashMap Engine.AliasKey Engine.AliasVerdict -- the run's alias verdicts; read only here
    }


{-| Builds a `LoadCtx` over `store` with empty memos and `sharedArrowMemo` as
the arrow memo, for tests that call `loadTypeC` directly. Passing an item's
arrow memo models a shared load, and `Dict.empty` an isolated one. The census is
off and the alias tables are empty.
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


{-| Builds the context for a shared load from the item's state: its store,
variable memo, reverse memo, arrow memo and ground-alias memo, so that repeated
type variables and repeated stamped arrows reuse the item's Points.
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


{-| Builds the context for an isolated load, a fresh instantiation: the variable
memo and the arrow memo start empty.

The arrow memo must start empty because every call site of an annotated function
loads the same annotation, with the same arrow ids; sharing the item's arrow
memo would give all those call sites one lambda set. The census map and the
ground-alias memo are the item's, since neither can join two call sites'
variables or set slots.

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
    , arrowOfSlot = s.itemAux.arrowOfSlot
    , groundLoads = s.itemAux.groundLoads
    , aliasMemo = s.monoMemo.aliasMemo
    }


{-| Writes a shared load's context back into `S`: the store, both memos, the
arrow memo, the ground-alias memo and the census map, and adds the slots it
minted to `lssStats.slotsMinted`.
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
    { s1 | itemAux = { aux | arrowMemo = c.arrowMemo, groundLoads = c.groundLoads, arrowOfSlot = c.arrowOfSlot } }


{-| Writes an isolated load's context back into `S`: the store, the reverse memo
and the ground-alias memo, and adds the slots it minted to
`lssStats.slotsMinted`. Neither the variable memo nor the arrow memo is written
back. The census map is written back when the census is on.
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


{-| Loads a canonical type into the item's store through the item's memos,
returning its root Point. A type variable that this type, or an earlier shared
load in the item, has already loaded gets the same Point.
-}
loadTypeS : Can.Type TypeIds.MVarId -> Engine.S -> ( Vars.Variable, Engine.S )
loadTypeS canType s =
    let
        ( v, c ) =
            loadTypeC s.env.superStatic canType (sharedLoadCtx s)
    in
    ( v, writeBackShared c s )


{-| Loads a canonical type through the item's memos as `loadTypeS` does.
-}
loadType : Can.Type TypeIds.MVarId -> Step Vars.Variable
loadType canType s =
    loadTypeS canType s


{-| Loads a canonical type as `loadTypeS` does, also returning the set slot of
every arrow the load passed, in the order it passed them. The array is empty with LSS
off.

A slot's position in the array is its arrow ordinal, which signature facts in
`Compiler.MonoSolver.LssInfer` are indexed by. The order is post-order: an
arrow's slot comes after the slots of the arrows inside its argument and result.
A slot reused through the arrow memo is still listed, so the same Point can
appear more than once.

-}
loadTypeWithArrows : Can.Type TypeIds.MVarId -> Engine.S -> ( ( Vars.Variable, Array Vars.Variable ), Engine.S )
loadTypeWithArrows canType s =
    let
        ( v, c ) =
            loadTypeC s.env.superStatic canType (sharedLoadCtx s)
    in
    ( ( v, Array.fromList (List.reverse c.arrowSlots) ), writeBackShared c s )


{-| Loads a canonical type as a fresh instantiation, as `loadTypeIsolated` does,
also returning its arrows' set slots in the order `loadTypeWithArrows`
describes.
-}
loadTypeIsolatedWithArrows : Can.Type TypeIds.MVarId -> Engine.S -> ( ( Vars.Variable, Array Vars.Variable ), Engine.S )
loadTypeIsolatedWithArrows canType s =
    let
        ( v, c ) =
            loadTypeC s.env.superStatic canType (isolatedLoadCtx s)
    in
    ( ( v, Array.fromList (List.reverse c.arrowSlots) ), writeBackIsolated c s )


{-| Loads a canonical type into the item's store as a fresh instantiation: its
type variables get Points that share nothing with the item's variable memo, and
neither the variable memo nor the arrow memo is updated. The new Points are
still recorded in the reverse memo, and ground alias instantiations still share
the item's ground-alias memo.
-}
loadTypeIsolated : Can.Type TypeIds.MVarId -> Engine.S -> ( Vars.Variable, Engine.S )
loadTypeIsolated canType s =
    let
        ( v, c ) =
            loadTypeC s.env.superStatic canType (isolatedLoadCtx s)
    in
    ( v, writeBackIsolated c s )


{-| Loads a canonical type into `c0`'s store, returning its root Point and the
updated context. `superStatic` gives the super class of each constrained type
variable, by `MVarId` key, and a new variable's Point is minted `FlexSuper` when
it has one and `FlexVar` otherwise.

Every structural node gets a fresh Point, except inside a reused ground alias
instantiation (below). With `lssOn` an arrow becomes a `FunL` with a set slot,
and otherwise a `Fun1` with none. The slot, never the arrow node, is remembered
in `arrowMemo` under the arrow's id, and a later arrow with the same id reuses
it. The node is not shared because its argument and result
may load to different Points on different loads, and sharing it would unify
unrelated types. A reused slot is still pushed onto `arrowSlots`, so ordinals
keep counting arrows, but is not counted in `slotsMinted`. An arrow with no
`Arrow` id (`NoArrow` or `SolverRoot`) always gets a fresh slot and is never
remembered, or every such arrow would share one slot.

An alias instantiation that is ground and arrow-free, as `aliasKeyOf` and
`aliasBodyEligible` decide, is fully loaded only once per store: later loads
reuse the root content of the first, and so its child Points, but always under a
fresh root Point. A shared root would make two type variables equivalent merely
because both were unified with the same alias occurrence.

-}
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
                -- A memo hit must still push the slot onto `arrowSlots`: a
                -- shorter ordinal array makes `LssInfer` poison the whole
                -- instantiation.
                let
                    -- The arrow's id plus one, or 0 for an arrow with no
                    -- `Arrow` id.
                    occKey =
                        case arrowSlot of
                            TypeIds.Arrow aid ->
                                Id.toComparable aid + 1

                            _ ->
                                0

                    memoKey =
                        occKey

                    -- Names the slot by its arrow for the census; 0 names
                    -- nothing.
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
                    -- No id: always mint and never remember, or all such arrows
                    -- would share a slot.
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
                                        -- Unreachable for an eligible body; skip
                                        -- the memo rather than crash.
                                        ( p, { c1 | store = store1 } )


{-| Loads an alias instantiation without the ground-alias memo. A `Filled` alias
loads its body. A `Holey` alias loads its arguments, binds each parameter's key
to its argument's Point in the memo while the body loads, and then restores what
the memo held for those keys before.
-}
loadAliasPlainC : Dict.Dict Int Vars.SuperType -> List ( TypeIds.MVarId, Can.Type TypeIds.MVarId ) -> Can.AliasType TypeIds.MVarId -> LoadCtx -> ( Vars.Variable, LoadCtx )
loadAliasPlainC superStatic args aliasType c0 =
    case aliasType of
        Can.Filled inner ->
            loadTypeC superStatic inner c0

        Can.Holey inner ->
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


{-| Mints a Point holding `content` in the context's store, at the outermost
rank and with no mark.
-}
freshVarC : Vars.Content -> LoadCtx -> ( Vars.Variable, LoadCtx )
freshVarC content c =
    let
        ( store1, pt ) =
            UF.fresh (IO.makeDescriptor content Type.outermostRank Type.noMark Nothing) c.store
    in
    ( pt, { c | store = store1 } )


{-| Mints a Point holding the structure `flat`.
-}
structC : Vars.FlatType -> LoadCtx -> ( Vars.Variable, LoadCtx )
structC flat c =
    freshVarC (Vars.Structure flat) c


{-| Returns the Point for the type variable `mvarId`: the memo's Point when it
has one, and otherwise a new Point, recorded in the memo and the reverse memo. A
new Point is `FlexSuper` when `superStatic` gives the variable a super class,
and `FlexVar` otherwise. Only that static table is read here; the run's super
table is consulted at zonk.
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


{-| Records `pt` as the memo's Point for `key`, and `mvarId` as the reverse
memo's entry for `pt` unless that entry is already set.
-}
recordVarC : Int -> TypeIds.MVarId -> Vars.Variable -> LoadCtx -> LoadCtx
recordVarC key mvarId pt c =
    { c
        | memo = Dict.insert key pt c.memo
        , revMemo =
            revMemoSetIfAbsent (Engine.pointKey pt) mvarId c.revMemo
    }


{-| Sets index `pk` of the reverse memo to `mvarId` unless that index already
holds an id, so the first variable to mint a Point names it. The array grows
with `Nothing` entries as needed.
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


{-| Loads each type in order, returning their Points.
-}
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


{-| Loads a record's extension: the extension variable's Point, or a fresh empty
record for a closed record.
-}
loadRecordExtC : Dict.Dict Int Vars.SuperType -> Maybe TypeIds.MVarId -> LoadCtx -> ( Vars.Variable, LoadCtx )
loadRecordExtC superStatic maybeExtension c =
    case maybeExtension of
        Just extMvarId ->
            loadVarC superStatic extMvarId c

        Nothing ->
            structC Vars.EmptyRecord1 c


{-| Loads each record field's type, returning the field Points by name.
-}
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


{-| Returns the home `Unify` expects for an elm/core primitive type: `Basics`
for `Int`, `Float` and `Bool`, and the `Char`, `String` and `List` modules for
those three. Every other type keeps its home.

The store compares the homes of type constructors, and a canonical type can name
an elm/core primitive under more than one elm/core module. Giving each one home
stops unification rejecting two spellings of one type. `Char`, `String` and
`List` take the homes that `Compiler.Type.Error`'s `isChar`, `isString` and
`isList` test for.

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



-- ====== ENCODE: MonoType -> store Point ======


{-| Mints one fresh set slot for each distinct set variable `LVar n` on the
arrows of `monoType`, returning the slots by `n`. Returns an empty map with LSS
off.

Encoding then gives every arrow labelled `LVar n` that one slot, so arrows whose
slots were unified when the type was zonked share a slot again once it is
encoded.

-}
mintVarSlots : Bool -> Mono.MonoType -> IO.State -> ( Dict.Dict Int Vars.Variable, IO.State )
mintVarSlots lssOn monoType st =
    if not lssOn then
        ( Dict.empty, st )

    else
        collectVarSlots monoType ( Dict.empty, st )


{-| Adds a fresh slot to the map for each set variable in `monoType` that does
not have one yet.
-}
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


{-| Encodes a demanded `MonoType` as fresh Points in the item's store,
returning the root Point. Neither memo is touched, so the result shares no Point
with a loaded type until the two are unified.

An `MVar` becomes a fresh variable, a `FlexSuper Number` one for `CNumber`. A
tuple with fewer than two elements also becomes a fresh variable. An `MFunction`
becomes a chain of one-argument arrows. With LSS on, each arrow's set slot is
filled from the function's annotation: `LTop k` writes ⊤ of kind `k`, `LSet`
writes its members, `LVar n` uses the one slot shared by every arrow in this
type labelled `n`, and `LPartial` leaves the slot unwritten, because its members
are only a lower bound and writing them would claim the set is complete.

-}
monoTypeToVarS : Mono.MonoType -> Engine.S -> ( Vars.Variable, Engine.S )
monoTypeToVarS monoType s =
    let
        ( varSlots, storeWithVars ) =
            mintVarSlots s.env.lss.enabled monoType s.store

        ( v, store1 ) =
            monoTypeToVarC s.env.lss.enabled varSlots monoType storeWithVars
    in
    ( v, { s | store = store1 } )


{-| Mints a Point holding `content` in `st`, at the outermost rank and with no
mark.
-}
freshVarS : Vars.Content -> IO.State -> ( Vars.Variable, IO.State )
freshVarS content st =
    let
        ( store1, pt ) =
            UF.fresh (IO.makeDescriptor content Type.outermostRank Type.noMark Nothing) st
    in
    ( pt, store1 )


{-| Mints a Point holding the structure `flat` in `st`.
-}
structS : Vars.FlatType -> IO.State -> ( Vars.Variable, IO.State )
structS flat st =
    freshVarS (Vars.Structure flat) st


{-| Encodes `monoType` as fresh Points in `st`, as `monoTypeToVarS` describes,
using `varSlots` for set variables.
-}
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
            -- One arrow per argument, built from the result outwards.
            let
                ( pResult, st1 ) =
                    monoTypeToVarC lssOn varSlots result st
            in
            if lssOn then
                let
                    slotContent =
                        case anno of
                            Mono.LTop tpK ->
                                IO.lsTopContentK tpK

                            Mono.LVar _ ->
                                -- Only when `varSlots` has no slot for `n`: a
                                -- fresh slot loses the sharing.
                                Vars.FlexVar Nothing

                            Mono.LSet members ->
                                Vars.Structure (Vars.LambdaSet1 (Vars.LsMembers members))

                            Mono.LPartial _ ->
                                -- A lower bound only: writing the members would
                                -- claim a complete set.
                                Vars.FlexVar Nothing

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


{-| Encodes each type in order, returning their Points.
-}
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


{-| Encodes each record field's type, returning the field Points by name.
-}
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


{-| Renders a type from a unification error with its full nesting, for a
mismatch message. `?` marks a flexible variable, `!` a rigid one, a following
`s` a constrained one, and `~name=` an alias followed by its expansion. Records
and tuples are shown only as `{..}` and `(,,)`.
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


{-| Unifies two store Points, reporting only whether it worked.

A failing unify leaves the store as the attempt left it, so a caller that means
to recover puts back the store it had before the call; the store is an
immutable value, so that older store is still intact.
`unifyStrict` below is the entry for callers that propagate the failure instead.

-}
unifyStep : Vars.Variable -> Vars.Variable -> Engine.S -> ( Bool, Engine.S )
unifyStep v1 v2 s0 =
    let
        ( ok, store1 ) =
            Unify.unifyBoolS v1 v2 s0.store
    in
    ( ok, { s0 | store = store1 } )


{-| Unifies two store Points as a `Step`, aborting the process with a
`UnifyMismatch` failure when they do not unify, as `unifyStrictS` does with an
empty context.
-}
unifyStrict : Vars.Variable -> Vars.Variable -> Step ()
unifyStrict v1 v2 s0 =
    ( (), unifyStrictS (\() -> "") v1 v2 s0 )


{-| Unifies two store Points, aborting the process with a `UnifyMismatch`
failure when they do not unify.

The failure message renders both types as `errDeep` does, names the global
being specialized, gives the current `joinRounds` and `retranslations`
counts, and ends with `ctx ()` when that is not empty. `ctx` is a function so
that the context is built only when the unify fails.

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


{-| Unifies two Points, keeping the result on success. On a mismatch the store
is put back as it was before the attempt, so a failure leaves no partial merges.
-}
unifyBestEffortStoreS : Vars.Variable -> Vars.Variable -> Engine.S -> Engine.S
unifyBestEffortStoreS v1 v2 s =
    case unifyStep v1 v2 s of
        ( True, s1 ) ->
            s1

        ( False, s1 ) ->
            { s1 | store = s.store }



-- ====== LSS ARROW HELPERS ======


{-| Returns the argument and result Points of an arrow's content, whether `Fun1`
or `FunL`, or `Nothing` for content that is not an arrow.
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


{-| Returns the set slot of a `FunL` arrow's content, and `Nothing` for a `Fun1`
arrow, which has none, or for anything that is not an arrow.
-}
arrowSetSlot : Vars.Content -> Maybe Vars.Variable
arrowSetSlot content =
    case content of
        Vars.Structure (Vars.FunL _ _ slot) ->
            Just slot

        _ ->
            Nothing


{-| Joins `(top, members)` into a set slot's content and writes the result into
the slot directly, without unification. `top` is `Just` a ⊤ kind to write ⊤, and
`members` must be ascending without duplicates, as it is stored as given.

A ⊤ slot does not change: ⊤ absorbs everything, and the kind already stored
stays. Writing ⊤ over members replaces them, and any deferred edges too. Members
written into a slot with members are merged in, and its deferred edges stay. An
unwritten slot takes the write as it is, except that a write with no members and
no ⊤ leaves it unwritten. Any other content becomes ⊤, which loses precision but
never drops a member.

Each write adds to one of the `setWrite` counters in `lssStats`, and when
`qOnFor` is true it is also recorded in the item's constraint log.

-}
unifySlotWithSet : Maybe Int -> List Int -> Vars.Variable -> Engine.S -> Engine.S
unifySlotWithSet top members slot s0 =
    foldSetWrites (unifySlotWithSetC top members slot (setWriteCtx (qOnFor s0) s0.store)) s0


{-| The state a run of set writes threads in place of `S`: the store, a count of
each kind of write, and the constraint log. `foldSetWrites` adds the counts to
`lssStats` and the log to the item once, at the end.

`skip` counts writes that changed nothing, `flex` writes into an unwritten slot,
`topJoin` ⊤ written over members, edges or unexpected content, and `union`
members merged into existing members. `qLog` is newest first, and is filled only
when `qOn`.

-}
type alias SetWriteCtx =
    { store : IO.State
    , skip : Int
    , flex : Int
    , topJoin : Int
    , union : Int
    , qOn : Bool
    , qLog : List Engine.QEntry
    }


{-| Tells whether set writes are recorded in the constraint log: when LSS and
`lss.qCensus` are both on.
-}
qOnFor : Engine.S -> Bool
qOnFor s =
    s.env.lss.enabled && s.env.lss.qCensus


{-| Creates a `SetWriteCtx` over `store` with zero counts and an empty
constraint log, which is filled only when `qOn` is true.
-}
setWriteCtx : Bool -> IO.State -> SetWriteCtx
setWriteCtx qOn store =
    { store = store, skip = 0, flex = 0, topJoin = 0, union = 0, qOn = qOn, qLog = [] }


{-| Records a write against `slot` in the context's constraint log, when the log
is on, together with what the slot held before the write (from `desc`). `top`
records a ⊤ write; otherwise the members are recorded.
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


{-| Returns what a slot held before a write: ⊤, its members (for a slot with
deferred edges, its members alone), or unconstrained for anything else.
-}
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


{-| Writes a run of set writes back into `S` in one update: the store, the write
counts added to `lssStats`, and the run's constraint log put in front of the
item's.
-}
foldSetWrites : SetWriteCtx -> Engine.S -> Engine.S
foldSetWrites c s0 =
    let
        stats0 =
            s0.lssStats

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


{-| Joins `(top, members)` into `slot` as `unifySlotWithSet` describes,
threading a `SetWriteCtx`.
-}
unifySlotWithSetC : Maybe Int -> List Int -> Vars.Variable -> SetWriteCtx -> SetWriteCtx
unifySlotWithSetC top members slot c0 =
    let
        ( store1, desc ) =
            UF.get slot c0.store

        -- Recorded before the join, while the slot's prior content is still
        -- known.
        c1 =
            noteQ (top /= Nothing) members slot desc { c0 | store = store1 }
    in
    case desc.content of
        Vars.Structure (Vars.LambdaSet1 (Vars.LsTop _)) ->
            -- ⊤ absorbs everything, and the first ⊤ kind stored stays.
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
            -- Members join the existing members and the deferred edges stay; ⊤
            -- replaces both.
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
            -- The usual target: a slot a load minted and nothing has written.
            case top of
                Just topK ->
                    setRootC slot desc (IO.lsTopContentK topK) { c1 | flex = c1.flex + 1 }

                Nothing ->
                    case members of
                        [] ->
                            -- No members and no ⊤ is the bottom: the slot stays
                            -- unwritten.
                            { c1 | skip = c1.skip + 1 }

                        _ ->
                            setRootC slot desc (Vars.Structure (Vars.LambdaSet1 (Vars.LsMembers members))) { c1 | flex = c1.flex + 1 }

        _ ->
            -- Not expected in a set slot. ⊤ loses precision but never drops a
            -- member.
            case top of
                Just topK ->
                    setRootC slot desc (IO.lsTopContentK topK) { c1 | topJoin = c1.topJoin + 1 }

                Nothing ->
                    setRootC slot desc IO.lsTopContent { c1 | topJoin = c1.topJoin + 1 }


{-| Replaces `slot`'s content with `content`, keeping the rest of its descriptor
`desc`.
-}
setRootC : Vars.Variable -> Vars.Descriptor -> Vars.Content -> SetWriteCtx -> SetWriteCtx
setRootC slot desc content c =
    let
        ( store1, () ) =
            UF.set slot { desc | content = content } c.store
    in
    { c | store = store1 }


{-| Compares two answers for each lambda-set class of the current item and adds
the result to the `qShadow` census in `lssStats`. Does nothing unless `qOnFor`
is true and the item recorded constraints.

A class is a set of slots the store has unified, named by its union-find
representative at the time of the census. The first answer is the least
solution of the item's constraint log: what each slot held before its first
constraint, plus every member and ⊤ written to it, plus whatever flows in over
recorded edges, repeated until nothing changes. The second is what the store holds, with
deferred edges followed but without zonk's set-size cap or honest-sources rule.
Each class is counted as agreeing, or as diverging in one of several ways, and
as reaching or not reaching the type at the item's recorded signature root
(`itemAux.qSigRoot`). A class whose slot is still unwritten is counted as
unresolved and not compared. A limited number of sample divergences are kept as
text.

The store the comparison produces is discarded, so only counters change.

-}
qShadowCensus : Engine.S -> Engine.S
qShadowCensus s =
    qCensusInto False (maybeList s.itemAux.qSigRoot) s


{-| Runs the comparison `qShadowCensus` describes with `roots` as the signature
roots, and adds the result to the `qInfer` census instead of `qShadow`.
-}
qInferenceCensus : List Vars.Variable -> Engine.S -> Engine.S
qInferenceCensus roots s =
    qCensusInto True roots s


{-| Returns a one-element list for `Just` and an empty list for `Nothing`.
-}
maybeList : Maybe a -> List a
maybeList m =
    case m of
        Just x ->
            [ x ]

        Nothing ->
            []


{-| Runs the comparison `qShadowCensus` describes with `roots` as the signature
roots, adding the result to `qInfer` when `toInfer` and to `qShadow` otherwise.
-}
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
                    -- union-find can compress paths, which changes the store.
                    -- The store the replay ends with is discarded and
                    -- `s.store` is kept, so the census leaves no trace.
                    acc =
                        -- `entries` is in reverse record order, so folding from
                        -- the head visits newest first and the OLDEST write of
                        -- each Point lands last, so each Point's oldest seed
                        -- is the one kept (`Dict.insert` overwrites).
                        List.foldl qStep (qAcc0 s.store) entries

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
                { s
                    | lssStats =
                        { stats
                            | sigStats =
                                if toInfer then
                                    { sig | qInfer = updated }

                                else
                                    { sig | qShadow = updated }
                        }
                }


{-| Returns the class keys of every set slot reachable from `root` through type
structure, which are the classes the signature reaches; none for `Nothing`.
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


{-| Walks the type structure from `v`, skipping Points in `seen`, and adds the
class key of every `FunL` set slot it meets to `acc`.
-}
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


{-| One class's value in the solution of the constraint log: ⊤, or a member
list. The members are empty whenever `top` is true.
-}
type alias QAns =
    { top : Bool, members : List Int }


{-| The empty answer: no members, and not ⊤.
-}
qBot : QAns
qBot =
    { top = False, members = [] }


{-| Returns the join of two answers: ⊤ if either is ⊤, and otherwise the union
of their ascending member lists.
-}
qJoin : QAns -> QAns -> QAns
qJoin a b =
    if a.top || b.top then
        { top = True, members = [] }

    else
        { top = False, members = IO.unionSortedAsc a.members b.members }


{-| Returns the answer a slot's prior content stands for: empty for an
unconstrained slot, ⊤, or its members.
-}
qOfPre : Engine.QPre -> QAns
qOfPre pre =
    case pre of
        Engine.PreFlex ->
            qBot

        Engine.PreTop ->
            { top = True, members = [] }

        Engine.PreMembers ms ->
            { top = False, members = ms }


{-| What replaying the constraint log collects: each slot's seed and class, the
direct constraints on each class, the edges between classes, a count of each
kind of constraint, and every member id the log mentions.
-}
type alias QAcc =
    { store : IO.State
    , seedByPoint : Dict.Dict Int Engine.QPre -- RAW pointKey -> its content before its first constraint
    , reprOf : Dict.Dict Int Int -- RAW pointKey -> repr key at census time
    , reprVar : Dict.Dict Int Vars.Variable -- repr key -> that class's representative Point (there is no key -> Point inverse)
    , direct : Dict.Dict Int QAns -- repr key -> members and ⊤ written directly to the class
    , edges : List ( Int, Int ) -- ( dst repr, src repr )
    , edgeDsts : Dict.Dict Int () -- repr keys that are the destination of some edge
    , nMembers : Int
    , nTops : Int
    , nEdges : Int
    , allMembers : Dict.Dict Int () -- every member id in the log's constraints and seeds
    }


{-| An empty accumulator over `store`.
-}
qAcc0 : IO.State -> QAcc
qAcc0 store =
    { store = store, seedByPoint = Dict.empty, reprOf = Dict.empty, reprVar = Dict.empty, direct = Dict.empty, edges = [], edgeDsts = Dict.empty, nMembers = 0, nTops = 0, nEdges = 0, allMembers = Dict.empty }


{-| Returns the class key of `v`, recording its class and `pre` as its seed. A
later call for the same Point replaces the seed, so the log is replayed newest
first for each Point's oldest seed to stay.
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


{-| Joins `ans` into the direct contribution of class `key`.
-}
qAddDirect : Int -> QAns -> QAcc -> QAcc
qAddDirect key ans a =
    { a | direct = Dict.insert key (qJoin ans (Maybe.withDefault qBot (Dict.get key a.direct))) a.direct }


{-| Adds one log entry to the accumulator: members or ⊤ as a direct contribution
to its slot's class, or an edge between two classes.
-}
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


{-| Returns the least solution of the recorded constraints, by class: each
class's seeds joined with its direct contributions, then joined with the answer
of every class an edge leads in from, repeated until nothing changes.

The answers only grow and are bounded, so the iteration ends; the round cap (one
more than the number of edges) is a backstop, and stopping at it can only make
an answer smaller.

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


{-| The counts one comparison of the two answers produces, with sample
divergences as text.
-}
type alias QCounts =
    { classes : Int, agree : Int, divergeSuper : Int, divergeSub : Int, divergeTop : Int, divergeOther : Int, unresolved : Int, edgeClasses : Int, reaching : Int, internal : Int, subMerged : Int, subUnseen : Int, internAgree : Int, internDiverge : Int, samples : List String }


{-| Zero counts and no samples.
-}
qCounts0 : QCounts
qCounts0 =
    { classes = 0, agree = 0, divergeSuper = 0, divergeSub = 0, divergeTop = 0, divergeOther = 0, unresolved = 0, edgeClasses = 0, reaching = 0, internal = 0, subMerged = 0, subUnseen = 0, internAgree = 0, internDiverge = 0, samples = [] }


{-| Compares the solved answer of each class with the store's, read from the
class's representative, and counts the results. A class is internal when the
signature does not reach it. Returns the counts and the store after the reads.
-}
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
                    -- The store gave no answer: nothing to compare.
                    ( { c1 | unresolved = c1.unresolved + 1 }, store1 )

                Just ans ->
                    ( qScore a.allMembers (not (Dict.member key sigClasses)) shadow ans c1, store1 )
        )
        ( qCounts0, a.store )
        solved


{-| Adds one class's comparison to the counts: agreement; disagreement on ⊤; the
solution holding fewer members than the store, split by whether every missing
member appears somewhere in the log; more members; or neither. An internal class
is also counted in `internAgree` or `internDiverge`, and a divergence adds a
sample while fewer than 40 are held.
-}
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
                -- Fewer members than the store: some write reached the store
                -- without being logged.
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


{-| Returns the store's answer for a class's representative: `Nothing` when
there is no representative or its slot holds no set content, and otherwise its ⊤
or members, with deferred edges followed. No read-time policy is applied.
-}
qEagerAt : Maybe Vars.Variable -> IO.State -> ( Maybe QAns, IO.State )
qEagerAt maybeVar store =
    case maybeVar of
        Nothing ->
            ( Nothing, store )

        Just v ->
            qEagerGo Dict.empty v store


{-| Reads `v`'s set content, following deferred edges and skipping Points in
`seen`; a ⊤ anywhere gives ⊤, and a source with no set content adds nothing.
-}
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


{-| Adds a deferred inclusion edge to the set slot `dst`: whatever `src` holds
when `dst` is read belongs to `dst`'s set too. The edge is followed at zonk, not
now, so members that `src` gains later still reach `dst`.

Nothing is written when the two slots are already unified, when `dst` is ⊤, or
when `dst` already has an edge from `src`. Unexpected content in `dst` becomes
⊤. Under `lss.report` each write, including the ⊤ fallback, is counted.
When `qOnFor` is true the edge is recorded in the constraint log whenever the
slots are not already unified.

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
                            -- An edge is a constraint too: `dst` includes
                            -- `src`.
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
                                -- Unexpected content: fail toward ⊤, since
                                -- dropping the edge could lose members.
                                write IO.lsTopContent s2


{-| Makes every set slot reachable from `v0` through arrows, type arguments,
records, tuples and aliases ⊤, so that no arrow in the type keeps a lambda set.
A slot not already ⊤ gets the poison kind; an existing ⊤ keeps its kind. Each
Point is visited once.
-}
poisonArrowSets : Vars.Variable -> Engine.S -> Engine.S
poisonArrowSets v0 s0 =
    foldSetWrites (poisonGoC Dict.empty [ v0 ] (setWriteCtx (qOnFor s0) s0.store)) s0


{-| Visits the Points in `worklist` depth first, skipping those in `seen`, and
writes ⊤ of the poison kind into the set slot of each `FunL` it meets.
-}
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
                        -- The store from `UF.get` is dropped: it differs only
                        -- by path compression.
                        UF.get v c0.store

                    c1 =
                        c0
                in
                case desc.content of
                    Vars.Structure flat ->
                        case flat of
                            Vars.FunL a b slot ->
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


{-| The state a zonk threads in place of `S`: the store, the next fresh residual
id, the intern table, the member table and next member id (grounding can add
members), the reads that are folded back into `S`, and the census accumulator.

`varOf` numbers the set variables of the one type being zonked, keyed by each
slot's union-find representative and allocated in the order the walk meets them;
it starts empty for every `zonkToMono`.

-}
type alias ZonkCtx =
    { store : IO.State
    , next : TypeIds.MVarId
    , lssOn : Bool -- lss.enabled
    , maxSetSize : Int -- larger member sets read back as ⊤; 0 means no limit
    , lss : Maybe LssZonkAcc -- census counters; Just only when lss.enabled and lss.report
    , ecoReads : List Vars.Variable -- reverse-memo-named variables read back as CEcoValue residuals
    , intern : Intern -- hash-cons table for zonked composites
    , memberTable : Engine.LssMemberTable -- grounding can intern member ids
    , nextMemberId : Int
    , arrowOf : Dict.Dict Int Int -- set slot Point key -> arrow key, read only; empty unless lss.report
    , varOf : Dict.Dict Int Int
    , nextVar : Int
    }


{-| Returns the interned (hash-consed) copy of a freshly built composite, adding
it to the context's table when it is new. Its children are already interned,
since zonk works bottom up. The context is copied only when the table grew.
-}
consC : Mono.MonoType -> ZonkCtx -> ( Mono.MonoType, ZonkCtx )
consC mt c =
    let
        ( mt1, intern1 ) =
            Intern.hashCons mt c.intern
    in
    -- `entries`, not `size`, because the table's widened-type memo can grow
    -- without a new entry.
    if Intern.entries intern1 == Intern.entries c.intern then
        ( mt1, c )

    else
        ( mt1, { c | intern = intern1 } )


{-| The census counters one zonk collects about how set slots read back.
`zonkToMono` adds them to `lssStats`, except `varArrows` and `setArrows`, which
only `rezonkSettled` reads.

The `cause` counters record why each slot read back what it did. `causeSet`
counts a member list within the size cap, `causePoison` a stored ⊤ of any kind,
`causeFlex` an unwritten slot, and `causeEdgeSet`, `causeEdgeEmpty` and
`causeEdgeTop` a slot with deferred edges that resolved to members, to nothing,
or to ⊤. `causeUnknown` counts both set-variable causes again, `causeFlex` plus
`causeEdgeEmpty`. A member list over the cap is counted in `widenedBySize`
instead. `causeEdgeTop` includes resolutions widened by the honest-sources rule,
which `mixedFlex` also counts.

`hist` and `widenedHist` count member-list sizes within and over the cap.
`multiSets` collects, by arrow key, the members read back at that arrow when
there were at least two. `setArrows` and `varArrows` count, by arrow key, the
readbacks that gave a member set and those that gave a set variable.

-}
type alias LssZonkAcc =
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


{-| Applies `f` to the census accumulator, when there is one.
-}
bumpCauseC : (LssZonkAcc -> LssZonkAcc) -> ZonkCtx -> ZonkCtx
bumpCauseC f c =
    case c.lss of
        Just acc ->
            { c | lss = Just (f acc) }

        Nothing ->
            c


{-| Reads a store Point back as a `MonoType`.

A type variable that is still unresolved reads back as `MVar id CNumber` when it
is constrained to `number` or the run's super table marks its id as one, and as
`MVar id CEcoValue` otherwise; no default type is chosen. The id is the `MVarId`
the reverse memo names for its Point, or a fresh one.

With LSS on, each arrow's set slot reads back as `LSet` only when its members
are known. A slot nothing has written, or one whose deferred edges reach no
members, reads back as a set variable `LVar n`, numbered within this type so
that arrows whose slots are unified share `n`. A stored or reachable ⊤, a set of
more than `lss.maxSetSize` members when that is positive, and members that
arrived alongside an edge from an unwritten slot read back as `LTop`. Members
are grounded with `Engine.groundSetMembers` before the size cap applies. Nothing
resolved is written back into the store.

Composite results are interned. A variable the reverse memo names that reads
back as a `CEcoValue` residual is added to the item's `ecoResidualReads`. Under
`lss.report` the Point is also logged for `rezonkSettled`; when LSS is also on,
the census counters are added to `lssStats`. The process is aborted on `Error`
content, and on set content outside an arrow's slot.

-}
zonkToMono : Vars.Variable -> Engine.S -> ( Mono.MonoType, Engine.S )
zonkToMono var s =
    let
        lssAcc =
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

                -- Logged for `rezonkSettled`, which calls `zonkToMonoC`
                -- directly and so does not log its replays.
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


{-| Replays every readback the item logged against the item's store as it is
now, and adds what the replay found to the `settled` census in `lssStats`. Does
nothing unless LSS and `lss.report` are both on.

Nothing else changes: the store, residual ids, intern table and member table the
replay ends with are discarded. The result shows how the item's readbacks come
out against the store at the time of the call.

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
                    -- paths, so its final store is discarded and `s.store`
                    -- is kept.
                    ctxN =
                        List.foldl
                            (\v c ->
                                -- The set-variable numbering is per readback,
                                -- as in `zonkToMono`, and `ecoReads` is
                                -- discarded with the context.
                                case zonkToMonoC s.superTable s.revMemo v { c | varOf = Dict.empty, nextVar = 0, ecoReads = [] } of
                                    ( _, c1 ) ->
                                        c1
                            )
                            { store = s.store, next = s.nextMVarId, lssOn = s.env.lss.enabled, maxSetSize = s.env.lss.maxSetSize, lss = Just acc0, ecoReads = [], intern = s.intern, memberTable = s.lssMemberTable, nextMemberId = s.nextMemberId, arrowOf = s.itemAux.arrowOfSlot, varOf = Dict.empty, nextVar = 0 }
                            log
                in
                case ctxN.lss of
                    Nothing ->
                        s

                    Just acc ->
                        let
                            stats =
                                s.lssStats

                            sig =
                                stats.sigStats

                            prev =
                                sig.settled
                        in
                        { s
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


{-| Adds a zonk's census counters to `lssStats`: the set counts and size
histograms, the grounding counts, the demand-side count of mixed resolutions,
the per-arrow member sets, and in `argFlowCensus` the `mixed|demand` keys and
the `zc|` cause and size keys, both in total and for the global being
specialized. Does nothing without an accumulator.
-}
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
                                if acc.grounded == 0 && acc.groundingDeferred == 0 then
                                    stats.grounding

                                else
                                    { grounded = stats.grounding.grounded + acc.grounded, deferred = stats.grounding.deferred + acc.groundingDeferred }
                            , sigStats =
                                -- The per-consumer keys name the current
                                -- global, which only `S` knows.
                                let
                                    causesTotal =
                                        acc.causeSet + acc.causePoison + acc.causeFlex + acc.causeEdgeSet + acc.causeEdgeEmpty + acc.causeEdgeTop + acc.causeUnknown
                                in
                                if acc.mixedFlex == 0 && causesTotal == 0 && Dict.isEmpty acc.multiSets then
                                    sig

                                else
                                    { sig
                                        | topMixedFlexDemand = sig.topMixedFlexDemand + acc.mixedFlex
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
                                                    -- Sets of two or more members, counted by
                                                    -- size.
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


{-| Adds `n` to `key`'s count in `census`, leaving the dict unchanged when `n`
is 0.
-}
bumpCensusKey : String -> Int -> Dict.Dict String Int -> Dict.Dict String Int
bumpCensusKey key n census =
    if n == 0 then
        census

    else
        Dict.insert key (n + Maybe.withDefault 0 (Dict.get key census)) census


{-| Reads `var` back as a `MonoType`, as `zonkToMono` describes, threading a
`ZonkCtx`. `superTable` is the run's super table and `revMemo` the item's
reverse memo.
-}
zonkToMonoC : Dict.Dict Int Vars.SuperType -> Array (Maybe TypeIds.MVarId) -> Vars.Variable -> ZonkCtx -> ( Mono.MonoType, ZonkCtx )
zonkToMonoC superTable revMemo var c0 =
    let
        ( _, desc ) =
            -- The store from `UF.get` is dropped: it differs only by path
            -- compression.
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
            ( Engine.crashFailure (EngineBug "Error content encountered in zonkToMono"), c0 )


{-| Returns the residual for an unresolved variable Point: `MVar id CNumber`
when `superTable` marks its id as a `number`, and otherwise `MVar id CEcoValue`,
adding the Point to `ecoReads` when the reverse memo names it.
-}
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
            -- Only variables the reverse memo names are recorded. Points no
            -- variable load minted, such as encoded demand variables, are not
            -- recorded.
            case Maybe.andThen identity (Array.get (Engine.pointKey var) revMemo) of
                Just _ ->
                    ( Mono.MVar mid Mono.CEcoValue, { c1 | ecoReads = var :: c1.ecoReads } )

                Nothing ->
                    ( Mono.MVar mid Mono.CEcoValue, c1 )


{-| Returns the id a residual Point reads back with: the `MVarId` the reverse
memo holds for it, or else the next fresh id.
-}
residualIdC : Array (Maybe TypeIds.MVarId) -> Vars.Variable -> ZonkCtx -> ( TypeIds.MVarId, ZonkCtx )
residualIdC revMemo var c =
    case Maybe.andThen identity (Array.get (Engine.pointKey var) revMemo) of
        Just mid ->
            ( mid, c )

        Nothing ->
            ( c.next, { c | next = Id.succ c.next } )


{-| Reads one structure back as a `MonoType`. Each arrow becomes a one-parameter
`MFunction`: a `FunL` annotated with what `zonkSetSlot` reads from its slot, and
a `Fun1` annotated ⊤ of the `declStoreC` kind.
-}
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
            -- Set content belongs only in an arrow's slot, which the `FunL` arm
            -- reads.
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


{-| Returns the set-variable number of `setVar` within the type being zonked,
allocating the next number the first time its class is met.

Numbers are keyed by the slot's union-find representative, so arrows whose slots
were unified read back the same `n`, and encoding the type again gives them one
slot. Numbers follow the walk's order, which the type's structure decides, so
two types with the same structure and the same sharing get the same numbers.

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


{-| Adds `members` to the census's member set for the arrow `setVar` belongs to,
when there are at least two members and the census is on.

The arrow is looked up by the slot's union-find representative first and then by
the slot itself. The slot read back is often not the one minted with the arrow:
a demand encoding mints slots with no arrow id, and unification can leave its
slot as the one the arrow carries.

-}
noteMultiSet : Vars.Variable -> List Int -> ZonkCtx -> ZonkCtx
noteMultiSet setVar members c =
    case c.lss of
        Just acc ->
            if List.length members < 2 then
                c

            else
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
                                    { acc
                                        | multiSets =
                                            Dict.insert akey
                                                (unionSortedMembers members (Maybe.withDefault [] (Dict.get akey acc.multiSets)))
                                                acc.multiSets
                                    }
                        }

        Nothing ->
            c


{-| Counts one readback of `setVar` against its arrow, in `setArrows` when
`resolved` and in `varArrows` otherwise, finding the arrow as `noteMultiSet`
does. Does nothing without a census accumulator or when no arrow is recorded for
the slot.
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


{-| Returns the ascending union of two ascending, duplicate-free member lists.
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


{-| Reads a set slot back as a lambda-set annotation. `paramT` and `resultT` are
the arrow's already zonked argument and result types, which grounding keys on.

A stored ⊤ reads back as `LTop` of its kind. A member list is grounded
(`Engine.groundSetMembers`) and reads back as `LSet`, or as `LTop` of the
`widen` kind when `maxSetSize` is positive and the grounded list is longer. A
slot with deferred edges is resolved as `resolveSlotMembers` describes: `LTop`
of the `edge` kind when that gives `Nothing`, a set variable when it gives no
members, and otherwise its members grounded and capped as above. With LSS off,
member and edge content read back as `LTop` of the `edge` kind. An unwritten
slot, or any other content, reads back as a set variable `LVar n` (see
`varNumberFor`), never as an empty set, which would claim that no function
reaches the arrow.

The resolution is not written back, so a later read follows the edges again and
sees sources that have grown since.

-}
zonkSetSlot : Mono.MonoType -> Mono.MonoType -> Vars.Variable -> ZonkCtx -> ( Mono.LambdaSetAnno, ZonkCtx )
zonkSetSlot paramT resultT setVar c0 =
    let
        ( _, desc ) =
            -- The store from `UF.get` is dropped: it differs only by path
            -- compression.
            UF.get setVar c0.store

        c1 =
            c0
    in
    case desc.content of
        Vars.Structure (Vars.LambdaSet1 (Vars.LsTop tpK)) ->
            ( Mono.topOfKind tpK, bumpCauseC (\a -> { a | causePoison = a.causePoison + 1 }) (bumpZonkAcc Nothing c1) )

        Vars.Structure (Vars.LambdaSet1 (Vars.LsMembers members0)) ->
            if c1.lssOn then
                let
                    ( members, c2 ) =
                        groundMembersC paramT resultT members0 c1

                    size =
                        List.length members
                in
                if c1.maxSetSize > 0 && size > c1.maxSetSize then
                    ( Mono.topWiden, bumpWidenedAcc size c2 )

                else
                    ( Mono.LSet members, noteArrowClass True setVar (noteMultiSet setVar members (bumpCauseC (\a -> { a | causeSet = a.causeSet + 1 }) (bumpZonkAcc (Just size) c2))) )

            else
                ( Mono.topEdge, c1 )

        Vars.Structure (Vars.LambdaSet1 (Vars.LsFrom members0 srcs)) ->
            -- Not written back: a later read must see sources that have grown.
            if c1.lssOn then
                case resolveSlotMembers members0 srcs c1 of
                    ( Nothing, c2 ) ->
                        -- A reachable ⊤, unexpected content or the honest-sources
                        -- rule makes the resolution ⊤.
                        ( Mono.topEdge, bumpCauseC (\a -> { a | causeEdgeTop = a.causeEdgeTop + 1 }) (bumpZonkAcc Nothing c2) )

                    ( Just [], c2 ) ->
                        -- Nothing reached is no information, not an empty set.
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
                        -- Resolve, then ground, then cap, as for a plain member
                        -- list.
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
            -- Unwritten: no information, never an empty set.
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


{-| Resolves a slot's deferred edges: returns `Nothing` when a ⊤ is reachable,
and otherwise `Just` the union of `members0` and the members of every slot
reachable through `srcs`.

With LSS on, the honest-sources rule also gives `Nothing` when the union has
members and the walk crossed an unwritten slot: that slot may yet receive
members, so the union may be incomplete, and an `LSet` claims completeness.
Content that is neither set content nor an unwritten variable counts as ⊤. Each
slot is visited once, by raw Point key, so cycles end, and the union over
everything reachable is the least solution. A resolution with members that
crossed an unwritten slot is counted in the census, when there is one.

The union is a merge of ascending lists, so it is ascending and free of
duplicates only when `members0` is.

-}
resolveSlotMembers : List Int -> List Vars.Variable -> ZonkCtx -> ( Maybe (List Int), ZonkCtx )
resolveSlotMembers members0 srcs c0 =
    resolveSlotMembersWith (hasLssAcc c0) members0 srcs c0


{-| Tells whether the honest-sources rule applies: whenever LSS is on.
-}
hasLssAcc : ZonkCtx -> Bool
hasLssAcc c =
    c.lssOn


{-| Resolves a slot's deferred edges as `resolveSlotMembers` does, applying the
honest-sources rule only when `honest` is true. A resolution with members that
crossed an unwritten slot is counted in the census whether or not the rule
applies.
-}
resolveSlotMembersWith : Bool -> List Int -> List Vars.Variable -> ZonkCtx -> ( Maybe (List Int), ZonkCtx )
resolveSlotMembersWith honest members0 srcs c0 =
    case resolveSources srcs [] False (Just members0) c0 of
        ( Nothing, _, c1 ) ->
            ( Nothing, c1 )

        ( Just ms, sawFlex, c1 ) ->
            if sawFlex && not (List.isEmpty ms) then
                -- Members plus an unwritten source: the set may be incomplete.
                ( if honest then
                    Nothing

                  else
                    Just ms
                , bumpMixedFlexDemand ms c1
                )

            else
                -- No unwritten source was crossed, or there are no members:
                -- nothing to widen.
                ( Just ms, c1 )


{-| Counts one mixed resolution in the census's `mixedFlex`, and also in
`mixedFlexGc` when the member table classes its members as `gc`.
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


{-| Walks the slots in `pending` depth first, skipping raw Point keys in
`visited`, and unions their members into `acc`. Returns `Nothing` once a ⊤ or
unexpected content is reached, and reports whether an unwritten slot was
crossed.
-}
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
                        -- The store from `UF.get` is dropped: it differs only
                        -- by path compression.
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
                        -- Adds nothing yet but may receive members later; note
                        -- the crossing.
                        resolveSources rest visited1 True acc c1

                    _ ->
                        -- Defensive: unknown content fails toward ⊤.
                        ( Nothing, sawFlex, c1 )


{-| Grounds `members0` with `Engine.groundSetMembers` against the context's
member table, keyed on the arrow's `paramT` and `resultT`, and adds the
grounding counts to the census. The members and context come back unchanged when
nothing was grounded or deferred.
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


{-| Counts one readback widened by the size cap, and the size of its set, in the
census.
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


{-| Counts one set-slot readback in the census, and adds its size to `hist` when
it read back as a set of `maybeSize` members.
-}
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


{-| Reads each Point back in order.
-}
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


{-| Reads each field's Point back, adds the fields to `base`, and returns the
interned record.
-}
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


{-| Returns the fields a record's extension reads back with: its fields when it
reads back as a record, and none when it reads back as anything else, such as a
residual variable.
-}
zonkRecordExtC : Dict.Dict Int Vars.SuperType -> Array (Maybe TypeIds.MVarId) -> Vars.Variable -> ZonkCtx -> ( Dict.Dict String Mono.MonoType, ZonkCtx )
zonkRecordExtC superTable revMemo ext c0 =
    case zonkToMonoC superTable revMemo ext c0 of
        ( mt, c1 ) ->
            case mt of
                Mono.MRecord _ fields ->
                    ( fields, c1 )

                _ ->
                    ( Dict.empty, c1 )


{-| Returns `classifyApp`'s type, interned against the context's table.
-}
classifyAppC : ModuleName.Canonical -> String -> List Mono.MonoType -> ZonkCtx -> ( Mono.MonoType, ZonkCtx )
classifyAppC canonical name args c =
    consC (classifyApp canonical name args) c


{-| Returns the `MonoType` of a type constructor applied to `args`. elm/core's
`Int`, `Float`, `Bool`, `Char`, `String` and `List`, under any elm/core module,
become the primitive types, and anything else a custom type. A `List` with other
than one argument becomes a list of unit.
-}
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



-- ====== CLASSIFY DIRECT: Can.Type -> MonoType without minting store structure ======


{-| Classifies a canonical type straight to a `MonoType`, without minting Points
for its structure.

Every arrow it builds is annotated ⊤ of kind `topKind`. A type variable that the
item's memo has bound is zonked from the store, so lambda sets on arrows inside
it survive. An unbound one becomes `MVar id CNumber` when the run's super table
marks it a `number`, and `MVar id CEcoValue` otherwise, in which case its key is
added to the item's `ecoResidualKeyReads`. A ground, arrow-free alias
instantiation is classified once per run and its result cached in the run's
alias memo, and an alias found ineligible is cached as such.

-}
classifyDirect : Int -> Can.Type TypeIds.MVarId -> Engine.S -> ( Mono.MonoType, Engine.S )
classifyDirect topKind canType s =
    case classifyGo topKind s Dict.empty canType of
        ( t, s1 ) ->
            ( t, s1 )


{-| Classifies `canType` as `classifyDirect` describes, with `aliasSubst` giving
the `MonoType` of each `Holey` alias parameter in scope.
-}
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
                            -- Bound by demand in this item: read the Point
                            -- back.
                            case zonkToMono pt s of
                                ( mono, sZ ) ->
                                    ( mono, sZ )

                        Nothing ->
                            case residualForVar mvarId s of
                                Mono.MVar _ Mono.CEcoValue ->
                                    -- Read free before entering the store;
                                    -- recorded so a later binding is noticed.
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
            -- A hit returns the interned object the first classify produced.
            -- `topKind` and `aliasSubst` cannot matter there: an eligible
            -- instantiation reaches no arrow and no variable outside its own
            -- parameters.
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
                                -- Record the ineligibility too, so a body walk is
                                -- paid once per instantiation rather than once
                                -- per occurrence.
                                case classifyAliasPlain topKind (Engine.putAliasVerdict key Engine.AliasIneligible s) aliasSubst args aliasType of
                                    ( t, s1 ) ->
                                        ( t, s1 )


{-| Classifies an alias instantiation without the alias memo: a `Filled` alias
by its body, and a `Holey` alias by its body with each parameter bound to its
argument, classified in the outer scope.
-}
classifyAliasPlain : Int -> Engine.S -> Dict.Dict Int Mono.MonoType -> List ( TypeIds.MVarId, Can.Type TypeIds.MVarId ) -> Can.AliasType TypeIds.MVarId -> ( Mono.MonoType, Engine.S )
classifyAliasPlain topKind s aliasSubst args aliasType =
    case aliasType of
        Can.Filled inner ->
            case classifyGo topKind s aliasSubst inner of
                ( t, s1 ) ->
                    ( t, s1 )

        Can.Holey inner ->
            case classifyAliasArgs topKind s aliasSubst args aliasSubst of
                ( newSubst, s1 ) ->
                    case classifyGo topKind s1 newSubst inner of
                        ( t, s2 ) ->
                            ( t, s2 )



-- ====== GROUND, ARROW-FREE ALIAS SUBTREES ======


{-| Mixes `x` into the hash `h`, giving a value in `[0, 2^26)`, by the same
formula as `Mono.mixHash`.
-}
mix : Int -> Int -> Int
mix h x =
    modBy 67108864 (h * 33 + modBy 67108864 x + 7)


{-| Returns a structural hash in `[0, 2^26)` for a type that is ground and
arrow-free, and `-1` for one with a type variable, an arrow or an open record.

Through a `Filled` alias only the body is examined, and the hash is the body's.
Through a `Holey` alias the arguments are hashed together with the alias's
module and name, and the body is checked only for arrows: its type variables are
the alias's parameters, and an open record in it is accepted too. Names are
hashed with `Eco.Hash.string`, whose results are never negative, so `-1` stays
distinguishable. This is a hash, not a key: different types can share one.

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
            -- A negative accumulator is kept for the remaining fields.
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


{-| Mixes the hashes of `ts` into `h` in order, giving `-1` as soon as one of
them is `-1`.
-}
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


{-| Tells whether a type contains no arrow. Type variables and open records are
accepted, as in an alias body, where they are parameters.
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


{-| Tells whether a type is ground and arrow-free in the sense of `groundHash`.
-}
groundNoArrow : Can.Type TypeIds.MVarId -> Bool
groundNoArrow t =
    groundHash t >= 0


{-| Returns the alias-memo key of an alias instantiation, or `Nothing` when an
argument has a type variable, an arrow or an open record.

Only the arguments are examined; whether the body qualifies is
`aliasBodyEligible`'s question. The key's hash mixes only the lengths of the
home's author, project and module names, so it separates homes poorly;
`Engine.aliasKeyEq` compares the home in full.

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


{-| Tells whether an alias's body qualifies an instantiation for the
ground-alias memos: a `Filled` body must be ground and arrow-free in the sense
of `groundHash`, and a `Holey` body need only contain no arrow, since its type
variables and open records are parameters.
-}
aliasBodyEligible : Can.AliasType TypeIds.MVarId -> Bool
aliasBodyEligible aliasType =
    case aliasType of
        Can.Filled inner ->
            groundHash inner >= 0

        Can.Holey inner ->
            noArrowBody inner


{-| Tells whether a type is ground and arrow-free. An alias instantiation needs
ground, arrow-free arguments (as `aliasKeyOf` decides), then is answered from
the run's alias verdicts in `aliasMemo` when it has one and by checking the
alias's body otherwise.
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


{-| Classifies each type in order.
-}
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


{-| Classifies each alias argument in `outerSubst`'s scope and binds its
parameter's key to the result in `acc`.
-}
classifyAliasArgs : Int -> Engine.S -> Dict.Dict Int Mono.MonoType -> List ( TypeIds.MVarId, Can.Type TypeIds.MVarId ) -> Dict.Dict Int Mono.MonoType -> ( Dict.Dict Int Mono.MonoType, Engine.S )
classifyAliasArgs topKind s outerSubst args acc =
    case args of
        [] ->
            ( acc, s )

        ( paramId, t ) :: rest ->
            case classifyGo topKind s outerSubst t of
                ( mt, s1 ) ->
                    classifyAliasArgs topKind s1 outerSubst rest (Dict.insert (Engine.mvarIdKey paramId) mt acc)


{-| Returns the fields a record's extension classifies with: its fields when it
classifies as a record, and none otherwise.
-}
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
                            ( Dict.empty, s1 )


{-| Classifies each field's type and adds it to `base`.
-}
classifyRecordFields : Int -> Engine.S -> Dict.Dict Int Mono.MonoType -> List ( String, Can.FieldType TypeIds.MVarId ) -> Dict.Dict String Mono.MonoType -> ( Dict.Dict String Mono.MonoType, Engine.S )
classifyRecordFields topKind s aliasSubst fields base =
    case fields of
        [] ->
            ( base, s )

        ( k, Can.FieldType _ t ) :: rest ->
            case classifyGo topKind s aliasSubst t of
                ( mt, s1 ) ->
                    classifyRecordFields topKind s1 aliasSubst rest (Dict.insert k mt base)


{-| Returns the residual for a type variable the item's memo has not bound, with
the variable's own id: `MVar id CNumber` when the run's super table marks it a
`number`, and `MVar id CEcoValue` otherwise.
-}
residualForVar : TypeIds.MVarId -> Engine.S -> Mono.MonoType
residualForVar mvarId s =
    case Dict.get (Engine.mvarIdKey mvarId) s.superTable of
        Just Vars.Number ->
            Mono.MVar mvarId Mono.CNumber

        _ ->
            Mono.MVar mvarId Mono.CEcoValue
