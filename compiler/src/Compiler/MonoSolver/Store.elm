module Compiler.MonoSolver.Store exposing
    ( classifyDirect
    , loadType
    , loadTypeIsolated
    , loadTypeWithArrows
    , loadTypeIsolatedWithArrows
    , arrowParts
    , arrowSetSlot
    , unifySlotWithSet
    , SetWriteCtx, setWriteCtx, unifySlotWithSetC, foldSetWrites
    , unifyBestEffort
    , poisonArrowSets
    , monoTypeToVar
    , unifyStep
    , zonkToMono
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
defaults numbers; the shared Prune close does that (MONO_028).

@docs loadType, monoTypeToVar, unifyStep, zonkToMono

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Intern as Intern exposing (Intern)
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeIds as TypeIds
import Compiler.Data.Id as Id
import Compiler.Elm.ModuleName as ModuleName
import Compiler.MonoSolver.Engine as Engine exposing (Failure(..), Step)
import Compiler.Type.Error as TErr
import Compiler.Type.Type as Type
import Compiler.Type.UnionFind as UF
import Compiler.Type.Unify as Unify
import Array exposing (Array)
import Dict
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
    , memo : Dict.Dict Int IO.Variable
    , revMemo : Array (Maybe TypeIds.MVarId)
    , lssOn : Bool -- mint FunL set slots (lambda-set specialization)
    , arrowSlots : List IO.Variable -- minted set slots, REVERSED minting order
    , slotsMinted : Int -- Phase 3 rider: unconstrained slot mints this load (sizes Phase 5's dead-slot population)
    }


loadType : Can.Type TypeIds.MVarId -> Step IO.Variable
loadType canType =
    \s ->
        let
            ( v, c ) =
                loadTypeC s.env.superStatic canType { store = s.store, memo = s.memo, revMemo = s.revMemo, lssOn = s.env.lss.enabled, arrowSlots = [], slotsMinted = 0 }
        in
        Ok
            ( v
            , if c.slotsMinted == 0 then
                { s | store = c.store, memo = c.memo, revMemo = c.revMemo }

              else
                let
                    stats =
                        s.lssStats
                in
                { s | store = c.store, memo = c.memo, revMemo = c.revMemo, lssStats = { stats | slotsMinted = stats.slotsMinted + c.slotsMinted } }
            )


{-| `loadType` additionally returning the minted arrow set slots in minting
order. **This function (with its isolated sibling) DEFINES arrow ordinals**
(LSS_006): `LssSignature.arrows` and fact application both index by position
in this array. Shared item memo — unit members loaded through one memo share
annotation Points (the Σ self-reference rule).
-}
loadTypeWithArrows : Can.Type TypeIds.MVarId -> Step ( IO.Variable, Array IO.Variable )
loadTypeWithArrows canType =
    \s ->
        let
            ( v, c ) =
                loadTypeC s.env.superStatic canType { store = s.store, memo = s.memo, revMemo = s.revMemo, lssOn = s.env.lss.enabled, arrowSlots = [], slotsMinted = 0 }
        in
        Ok
            ( ( v, Array.fromList (List.reverse c.arrowSlots) )
            , if c.slotsMinted == 0 then
                { s | store = c.store, memo = c.memo, revMemo = c.revMemo }

              else
                let
                    stats =
                        s.lssStats
                in
                { s | store = c.store, memo = c.memo, revMemo = c.revMemo, lssStats = { stats | slotsMinted = stats.slotsMinted + c.slotsMinted } }
            )


{-| `loadTypeIsolated` additionally returning the minted arrow set slots in
minting order (fresh per-call-site instantiation; see `loadTypeWithArrows`
for the ordinal contract).
-}
loadTypeIsolatedWithArrows : Can.Type TypeIds.MVarId -> Step ( IO.Variable, Array IO.Variable )
loadTypeIsolatedWithArrows canType =
    \s ->
        let
            ( v, c ) =
                loadTypeC s.env.superStatic canType { store = s.store, memo = Dict.empty, revMemo = s.revMemo, lssOn = s.env.lss.enabled, arrowSlots = [], slotsMinted = 0 }
        in
        Ok
            ( ( v, Array.fromList (List.reverse c.arrowSlots) )
            , if c.slotsMinted == 0 then
                { s | store = c.store, revMemo = c.revMemo }

              else
                let
                    stats =
                        s.lssStats
                in
                { s | store = c.store, revMemo = c.revMemo, lssStats = { stats | slotsMinted = stats.slotsMinted + c.slotsMinted } }
            )


{-| D8: load a scheme with an ISOLATED (empty) memo so its vars do not share
Points with the surrounding item — a fresh instantiation — writing `S` back
ONCE. Replaces `Translate.instantiate`'s three S-copies (memo:=empty, loadType's
internal write, memo-restore) with a single write: the isolated memo is threaded
internally and discarded, and `s.memo` is never touched. Byte-identical (same
Points minted in the same order; store + revMemo updated; memo unchanged).
-}
loadTypeIsolated : Can.Type TypeIds.MVarId -> Step IO.Variable
loadTypeIsolated canType =
    \s ->
        let
            ( v, c ) =
                loadTypeC s.env.superStatic canType { store = s.store, memo = Dict.empty, revMemo = s.revMemo, lssOn = s.env.lss.enabled, arrowSlots = [], slotsMinted = 0 }
        in
        Ok
            ( v
            , if c.slotsMinted == 0 then
                { s | store = c.store, revMemo = c.revMemo }

              else
                let
                    stats =
                        s.lssStats
                in
                { s | store = c.store, revMemo = c.revMemo, lssStats = { stats | slotsMinted = stats.slotsMinted + c.slotsMinted } }
            )


loadTypeC : Dict.Dict Int IO.SuperType -> Can.Type TypeIds.MVarId -> LoadCtx -> ( IO.Variable, LoadCtx )
loadTypeC superStatic canType c0 =
    case canType of
        Can.TVar mvarId ->
            loadVarC superStatic mvarId c0

        Can.TLambda from to ->
            let
                ( pFrom, c1 ) =
                    loadTypeC superStatic from c0

                ( pTo, c2 ) =
                    loadTypeC superStatic to c1
            in
            if c2.lssOn then
                -- LSS: slot every arrow. The unconstrained FlexVar slot reads
                -- back LTop at zonk; ordinals = minting order (LSS_006).
                let
                    ( pSet, c3 ) =
                        freshVarC (IO.FlexVar Nothing) c2
                in
                structC (IO.FunL pFrom pTo pSet) { c3 | arrowSlots = pSet :: c3.arrowSlots, slotsMinted = c3.slotsMinted + 1 }

            else
                structC (IO.Fun1 pFrom pTo) c2

        Can.TType canonical name args ->
            let
                ( pArgs, c1 ) =
                    loadListC superStatic args c0
            in
            structC (IO.App1 (normalizePrimHome canonical name) name pArgs) c1

        Can.TRecord fields maybeExtension ->
            let
                ( pExt, c1 ) =
                    loadRecordExtC superStatic maybeExtension c0

                ( pFields, c2 ) =
                    loadRecordFieldsC superStatic (Dict.toList fields) c1
            in
            structC (IO.Record1 pFields pExt) c2

        Can.TUnit ->
            structC IO.Unit1 c0

        Can.TTuple a b rest ->
            let
                ( pa, c1 ) =
                    loadTypeC superStatic a c0

                ( pb, c2 ) =
                    loadTypeC superStatic b c1

                ( pRest, c3 ) =
                    loadListC superStatic rest c2
            in
            structC (IO.Tuple1 pa pb pRest) c3

        Can.TAlias _ _ _ (Can.Filled inner) ->
            loadTypeC superStatic inner c0

        Can.TAlias _ _ args (Can.Holey inner) ->
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


freshVarC : IO.Content -> LoadCtx -> ( IO.Variable, LoadCtx )
freshVarC content c =
    let
        ( store1, pt ) =
            UF.fresh (IO.makeDescriptor content Type.outermostRank Type.noMark Nothing) c.store
    in
    ( pt, { c | store = store1 } )


structC : IO.FlatType -> LoadCtx -> ( IO.Variable, LoadCtx )
structC flat c =
    freshVarC (IO.Structure flat) c


{-| Load or reuse the Point for a type variable, minting from the STATIC super
truth only (see the Step-era note; taint is consulted at zonk time, never here).
-}
loadVarC : Dict.Dict Int IO.SuperType -> TypeIds.MVarId -> LoadCtx -> ( IO.Variable, LoadCtx )
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
                            IO.FlexSuper superType Nothing

                        Nothing ->
                            IO.FlexVar Nothing

                ( pt, c1 ) =
                    freshVarC content c
            in
            ( pt, recordVarC key mvarId pt c1 )


recordVarC : Int -> TypeIds.MVarId -> IO.Variable -> LoadCtx -> LoadCtx
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


loadListC : Dict.Dict Int IO.SuperType -> List (Can.Type TypeIds.MVarId) -> LoadCtx -> ( List IO.Variable, LoadCtx )
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


loadRecordExtC : Dict.Dict Int IO.SuperType -> Maybe TypeIds.MVarId -> LoadCtx -> ( IO.Variable, LoadCtx )
loadRecordExtC superStatic maybeExtension c =
    case maybeExtension of
        Just extMvarId ->
            loadVarC superStatic extMvarId c

        Nothing ->
            structC IO.EmptyRecord1 c


loadRecordFieldsC : Dict.Dict Int IO.SuperType -> List ( String, Can.FieldType TypeIds.MVarId ) -> LoadCtx -> ( Dict.Dict String IO.Variable, LoadCtx )
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
normalizePrimHome : IO.Canonical -> String -> IO.Canonical
normalizePrimHome canonical name =
    case canonical of
        IO.Canonical ( "elm", "core" ) _ ->
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


{-| Encode a demanded MonoType as concrete store structure, the dual of the
`zonkToMono` classification. M6.0: threads only the store (`monoTypeToVar` mints
structure Points but touches neither memo nor revMemo), writing `S` back once
instead of once per node. Byte-identical (same Points minted in the same order).
-}
monoTypeToVar : Mono.MonoType -> Step IO.Variable
monoTypeToVar monoType =
    \s ->
        let
            ( v, store1 ) =
                monoTypeToVarC s.env.lss.enabled monoType s.store
        in
        Ok ( v, { s | store = store1 } )


freshVarS : IO.Content -> IO.State -> ( IO.Variable, IO.State )
freshVarS content st =
    let
        ( store1, pt ) =
            UF.fresh (IO.makeDescriptor content Type.outermostRank Type.noMark Nothing) st
    in
    ( pt, store1 )


structS : IO.FlatType -> IO.State -> ( IO.Variable, IO.State )
structS flat st =
    freshVarS (IO.Structure flat) st


monoTypeToVarC : Bool -> Mono.MonoType -> IO.State -> ( IO.Variable, IO.State )
monoTypeToVarC lssOn monoType st =
    case monoType of
        Mono.MInt ->
            structS (IO.App1 ModuleName.basics "Int" []) st

        Mono.MFloat ->
            structS (IO.App1 ModuleName.basics "Float" []) st

        Mono.MBool ->
            structS (IO.App1 ModuleName.basics "Bool" []) st

        Mono.MChar ->
            structS (IO.App1 ModuleName.char "Char" []) st

        Mono.MString ->
            structS (IO.App1 ModuleName.string "String" []) st

        Mono.MUnit ->
            structS IO.Unit1 st

        Mono.MList _ inner ->
            let
                ( p, st1 ) =
                    monoTypeToVarC lssOn inner st
            in
            structS (IO.App1 ModuleName.list "List" [ p ]) st1

        Mono.MTuple _ elems ->
            case elems of
                a :: b :: rest ->
                    let
                        ( pa, st1 ) =
                            monoTypeToVarC lssOn a st

                        ( pb, st2 ) =
                            monoTypeToVarC lssOn b st1

                        ( pRest, st3 ) =
                            monoListToVarC lssOn rest st2
                    in
                    structS (IO.Tuple1 pa pb pRest) st3

                _ ->
                    -- Degenerate tuple; encode as a fresh var rather than crash.
                    freshVarS (IO.FlexVar Nothing) st

        Mono.MRecord _ fields ->
            let
                ( pFields, st1 ) =
                    recordFieldPointsC lssOn (Dict.toList fields) st

                ( ext, st2 ) =
                    structS IO.EmptyRecord1 st1
            in
            structS (IO.Record1 pFields ext) st2

        Mono.MCustom _ home name args ->
            let
                ( pArgs, st1 ) =
                    monoListToVarC lssOn args st
            in
            structS (IO.App1 home name pArgs) st1

        Mono.MFunction _ anno args result ->
            -- Fold args right-to-left into nested Fun1 (one arg per arrow).
            -- Under lss, fold into FunL whose slots carry the annotation's
            -- content. Deliberate asymmetry with zonkSetSlot: a DEMAND's LTop
            -- encodes as top=True (poison — "some caller was widened, this
            -- arrow must stay dynamic"), while an unconstrained slot merely
            -- READS BACK as LTop without ever having poisoned anything.
            let
                ( pResult, st1 ) =
                    monoTypeToVarC lssOn result st
            in
            if lssOn then
                let
                    setContent =
                        case anno of
                            Mono.LTop ->
                                IO.LambdaSet1 IO.LsTop

                            Mono.LSet members ->
                                -- Phase 2: the LSet list IS the store
                                -- representation — reused by pointer, no
                                -- Dict.fromList conversion.
                                IO.LambdaSet1 (IO.LsMembers members)
                in
                List.foldl
                    (\argType ( accPoint, stA ) ->
                        let
                            ( pa, stA1 ) =
                                monoTypeToVarC lssOn argType stA

                            ( pSet, stA2 ) =
                                freshVarS (IO.Structure setContent) stA1
                        in
                        structS (IO.FunL pa accPoint pSet) stA2
                    )
                    ( pResult, st1 )
                    (List.reverse args)

            else
                List.foldl
                    (\argType ( accPoint, stA ) ->
                        let
                            ( pa, stA1 ) =
                                monoTypeToVarC lssOn argType stA
                        in
                        structS (IO.Fun1 pa accPoint) stA1
                    )
                    ( pResult, st1 )
                    (List.reverse args)

        Mono.MVar _ Mono.CNumber ->
            freshVarS (IO.FlexSuper IO.Number Nothing) st

        Mono.MVar _ Mono.CEcoValue ->
            freshVarS (IO.FlexVar Nothing) st


monoListToVarC : Bool -> List Mono.MonoType -> IO.State -> ( List IO.Variable, IO.State )
monoListToVarC lssOn types st =
    case types of
        [] ->
            ( [], st )

        t :: rest ->
            let
                ( p, st1 ) =
                    monoTypeToVarC lssOn t st

                ( ps, st2 ) =
                    monoListToVarC lssOn rest st1
            in
            ( p :: ps, st2 )


recordFieldPointsC : Bool -> List ( String, Mono.MonoType ) -> IO.State -> ( Dict.Dict String IO.Variable, IO.State )
recordFieldPointsC lssOn fields st =
    List.foldl
        (\( k, t ) ( acc, stA ) ->
            let
                ( pt, stA1 ) =
                    monoTypeToVarC lssOn t stA
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


{-| Unify two Points. A mismatch is a hard failure (no fallback): the real
unifier rejected something, which is a compiler bug or an M2+ gap.
-}
errKind : TErr.Type -> String
errKind t =
    case t of
        TErr.Lambda _ _ _ ->
            "Lambda"

        TErr.Infinite ->
            "INFINITE"

        TErr.Error ->
            "Error"

        TErr.FlexVar _ ->
            "FlexVar"

        TErr.FlexSuper _ _ ->
            "FlexSuper"

        TErr.RigidVar _ ->
            "RigidVar"

        TErr.RigidSuper _ _ ->
            "RigidSuper"

        TErr.Type _ n _ ->
            "Type:" ++ n

        TErr.Record _ _ ->
            "Record"

        TErr.Unit ->
            "Unit"

        TErr.Tuple _ _ _ ->
            "Tuple"

        TErr.Alias _ n _ _ ->
            "Alias:" ++ n


unifyStep : IO.Variable -> IO.Variable -> Step ()
unifyStep v1 v2 =
    Engine.andThen
        (\answer ->
            case answer of
                Unify.AnswerOk _ ->
                    Engine.succeed ()

                Unify.AnswerErr _ t1 t2 ->
                    -- Diagnostic context: the spec being translated + flush state
                    (\s ->
                        Engine.fail
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
                                )
                            )
                            s
                    )
        )
        (Engine.liftIO (Unify.unify v1 v2))


{-| Best-effort unify: a mismatch is swallowed, restoring the pre-unify state
(free via Elm's persistent arrays — the failed attempt's partial merges are
simply not kept). Used by the LSS inference walk, where structural failure
means "no set flow here", never "abort the item".
-}
unifyBestEffort : IO.Variable -> IO.Variable -> Step ()
unifyBestEffort v1 v2 s =
    case unifyStep v1 v2 s of
        Ok ( _, s1 ) ->
            Ok ( (), s1 )

        Err _ ->
            Ok ( (), s )



-- ====== LSS ARROW HELPERS ======


{-| The (param, rest) of an arrow content, whichever arrow form it is. The
single dispatch point that lets param-walkers handle `Fun1` and `FunL`
uniformly (identical Fun1 semantics when lss is off).
-}
arrowParts : IO.Content -> Maybe ( IO.Variable, IO.Variable )
arrowParts content =
    case content of
        IO.Structure (IO.Fun1 pParam pRest) ->
            Just ( pParam, pRest )

        IO.Structure (IO.FunL pParam pRest _) ->
            Just ( pParam, pRest )

        _ ->
            Nothing


{-| The set slot of a slotted arrow's content (Nothing for `Fun1` — no slot
to constrain — and for non-arrows).
-}
arrowSetSlot : IO.Content -> Maybe IO.Variable
arrowSetSlot content =
    case content of
        IO.Structure (IO.FunL _ _ slot) ->
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
unifySlotWithSet : Bool -> List Int -> IO.Variable -> Step ()
unifySlotWithSet top members slot s0 =
    -- Phase 3: one thin wrapper over the ctx-threaded engine — a single S
    -- rebuild per call, exactly as before.
    foldSetWrites (unifySlotWithSetC top members slot (setWriteCtx s0.store)) s0


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
    , needSlow : List ( Bool, List Int, IO.Variable )
    }


setWriteCtx : IO.State -> SetWriteCtx
setWriteCtx store =
    { store = store, skip = 0, flex = 0, topJoin = 0, union = 0, needSlow = [] }


{-| Fold a traversal's writes back into `S` with ONE copy, then run any
deferred defensive-arm writes through the Step-shaped slow path.
-}
foldSetWrites : SetWriteCtx -> Step ()
foldSetWrites c s0 =
    let
        stats0 =
            s0.lssStats

        s1 =
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
    in
    case c.needSlow of
        [] ->
            Ok ( (), s1 )

        slots ->
            foldSlowWrites slots s1


foldSlowWrites : List ( Bool, List Int, IO.Variable ) -> Step ()
foldSlowWrites items s0 =
    case items of
        [] ->
            Ok ( (), s0 )

        ( top, members, slot ) :: rest ->
            case unifySlotWithSetSlow top members slot s0 of
                Err e ->
                    Err e

                Ok ( (), s1 ) ->
                    foldSlowWrites rest s1


{-| The set-write engine (join semantics and counter mapping exactly as the
Phase 2 Step form; see that commit's doc). Total on live content; the
defensive arm defers to the boundary via `needSlow`.
-}
unifySlotWithSetC : Bool -> List Int -> IO.Variable -> SetWriteCtx -> SetWriteCtx
unifySlotWithSetC top members slot c0 =
    let
        ( store1, desc ) =
            UF.get slot c0.store

        c1 =
            { c0 | store = store1 }
    in
    case desc.content of
        IO.Structure (IO.LambdaSet1 IO.LsTop) ->
            -- ⊤ absorbs everything (terminal): pure skip.
            { c1 | skip = c1.skip + 1 }

        IO.Structure (IO.LambdaSet1 (IO.LsMembers cur)) ->
            if top then
                setRootC slot desc IO.lsTopContent { c1 | topJoin = c1.topJoin + 1 }

            else
                case IO.classifySorted members cur of
                    IO.SortedEqual ->
                        { c1 | skip = c1.skip + 1 }

                    IO.SortedSub ->
                        -- members ⊆ cur (covers members == [] too).
                        { c1 | skip = c1.skip + 1 }

                    IO.SortedSuper ->
                        -- cur ⊆ members: the union IS the caller's list —
                        -- adopt it by pointer, no merge allocation.
                        setRootC slot desc (IO.Structure (IO.LambdaSet1 (IO.LsMembers members))) { c1 | union = c1.union + 1 }

                    IO.SortedMixed ->
                        setRootC slot desc (IO.Structure (IO.LambdaSet1 (IO.LsMembers (IO.unionSortedAsc members cur)))) { c1 | union = c1.union + 1 }

        IO.FlexVar _ ->
            -- The DOMINANT case (Run B: 70.1 %): LSS_006 makes loadType mint
            -- fresh arrow structure per load, so a set write almost always
            -- targets an unconstrained flex slot. Adopt the content directly;
            -- the caller's list is stored AS-IS (ascending at every caller).
            if top then
                setRootC slot desc IO.lsTopContent { c1 | flex = c1.flex + 1 }

            else
                case members of
                    [] ->
                        -- (False, []) is bottom: a no-op that keeps the slot
                        -- unconstrained, preserving LsMembers-non-empty.
                        { c1 | skip = c1.skip + 1 }

                    _ ->
                        setRootC slot desc (IO.Structure (IO.LambdaSet1 (IO.LsMembers members))) { c1 | flex = c1.flex + 1 }

        _ ->
            -- DEFENSIVE only: unreachable by closure of the slot-content
            -- channels (LSS_007); measured 0 (Run C). Deferred to the
            -- traversal boundary.
            { c1 | needSlow = ( top, members, slot ) :: c1.needSlow }


setRootC : IO.Variable -> IO.Descriptor -> IO.Content -> SetWriteCtx -> SetWriteCtx
setRootC slot desc content c =
    let
        ( store1, () ) =
            UF.set slot { desc | content = content } c.store
    in
    { c | store = store1 }


unifySlotWithSetSlow : Bool -> List Int -> IO.Variable -> Step ()
unifySlotWithSetSlow top members slot s0 =
    let
        stats0 =
            s0.lssStats

        s1 =
            { s0 | lssStats = { stats0 | setWriteSlow = stats0.setWriteSlow + 1 } }

        set =
            if top then
                IO.LsTop

            else
                IO.LsMembers members
    in
    case Engine.freshVar (IO.Structure (IO.LambdaSet1 set)) s1 of
        Err e ->
            Err e

        Ok ( setVar, s2 ) ->
            unifyStep slot setVar s2


{-| Poison every arrow set slot reachable in a loaded type structure: kernels
apply closures through the generic runtime path, so any arrow crossing the
kernel/port ABI is dynamic (LSS_004). Point-indexed `seen` set guards against
revisits; store structure is finite.
-}
poisonArrowSets : IO.Variable -> Step ()
poisonArrowSets v0 s0 =
    -- Phase 3: ctx-threaded DFS — one ~6-field ctx copy per visited node and
    -- ONE S write-back here, where the old shape copied the full S record per
    -- visited node.
    foldSetWrites (poisonGoC Dict.empty [ v0 ] (setWriteCtx s0.store)) s0


poisonGoC : Dict.Dict Int () -> List IO.Variable -> SetWriteCtx -> SetWriteCtx
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

                    ( store1, desc ) =
                        UF.get v c0.store

                    c1 =
                        { c0 | store = store1 }
                in
                case desc.content of
                    IO.Structure flat ->
                        case flat of
                            IO.FunL a b slot ->
                                poisonGoC seen1 (a :: b :: rest) (unifySlotWithSetC True [] slot c1)

                            IO.Fun1 a b ->
                                poisonGoC seen1 (a :: b :: rest) c1

                            IO.App1 _ _ args ->
                                poisonGoC seen1 (args ++ rest) c1

                            IO.Record1 fields ext ->
                                poisonGoC seen1 (Dict.values fields ++ (ext :: rest)) c1

                            IO.Tuple1 a b cs ->
                                poisonGoC seen1 (a :: b :: cs ++ rest) c1

                            IO.EmptyRecord1 ->
                                poisonGoC seen1 rest c1

                            IO.Unit1 ->
                                poisonGoC seen1 rest c1

                            IO.LambdaSet1 _ ->
                                poisonGoC seen1 rest c1

                    IO.Alias _ _ _ real ->
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
    , lss : Maybe LssZonkAcc -- Just iff lss.enabled; keeps the off path lean
    , ecoReads : List IO.Variable -- MONO_029 stale-read barrier: vars read FREE while producing a CEcoValue residual (folded into S.ecoResidualReads)
    , intern : Intern -- K6: hash-cons table, carried in from S and written back once by `zonkToMono`
    , memberTable : Engine.LssMemberTable -- LSS_019: carried in from S, written back once (zonk grounding interns ground member ids)
    , nextMemberId : Int -- ditto (grounding may allocate fresh member ids)
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
    if Intern.size intern1 == Intern.size c.intern then
        ( mt1, c )

    else
        ( mt1, { c | intern = intern1 } )


{-| Set-slot readback accumulator (maxSetSize policy + census counters,
folded back into `S.lssStats` by the `zonkToMono` wrapper).
-}
type alias LssZonkAcc =
    { maxSetSize : Int
    , zonked : Int
    , widenedBySize : Int
    , hist : Dict.Dict Int Int

    -- Phase 1 census (plans/lss-set-write-substrate.md): `hist` is fed only on
    -- the WITHIN-cap branch, so the sizes of sets that widen are thrown away
    -- today — exactly the magnitudes the sorted-list worst case needs.
    , widenedHist : Dict.Dict Int Int

    -- LSS_019 standalone-member grounding (plans/lss-fidelity-2-standalone-member-grounding.md):
    -- the flag gates the whole rewrite (flag-off zonk is allocation-identical
    -- to pre-plan); the counters fold into `lssStats.grounding`.
    , groundStandalones : Bool
    , grounded : Int
    , groundingDeferred : Int
    }


zonkToMono : IO.Variable -> Step Mono.MonoType
zonkToMono var =
    \s ->
        let
            lssAcc =
                if s.env.lss.enabled then
                    Just { maxSetSize = s.env.lss.maxSetSize, zonked = 0, widenedBySize = 0, hist = Dict.empty, widenedHist = Dict.empty, groundStandalones = s.env.lss.groundStandalones, grounded = 0, groundingDeferred = 0 }

                else
                    Nothing
        in
        case zonkToMonoC s.superTable s.revMemo var { store = s.store, next = s.nextMVarId, lss = lssAcc, ecoReads = [], intern = s.intern, memberTable = s.lssMemberTable, nextMemberId = s.nextMemberId } of
            Err e ->
                Err e

            Ok ( mt, c ) ->
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
                in
                Ok ( mt, foldZonkStats c s1 )


foldZonkStats : ZonkCtx -> Engine.S -> Engine.S
foldZonkStats c s =
    case c.lss of
        Nothing ->
            s

        Just acc ->
            if acc.zonked == 0 && acc.widenedBySize == 0 then
                s

            else
                let
                    stats =
                        s.lssStats
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
                        }
                }


zonkToMonoC : Dict.Dict Int IO.SuperType -> Array (Maybe TypeIds.MVarId) -> IO.Variable -> ZonkCtx -> Result Failure ( Mono.MonoType, ZonkCtx )
zonkToMonoC superTable revMemo var c0 =
    let
        ( store1, desc ) =
            UF.get var c0.store

        c1 =
            { c0 | store = store1 }
    in
    case desc.content of
        IO.Structure flat ->
            zonkFlatC superTable revMemo flat c1

        IO.Alias _ _ _ real ->
            zonkToMonoC superTable revMemo real c1

        IO.FlexSuper IO.Number _ ->
            let
                ( mid, c2 ) =
                    residualIdC revMemo var c1
            in
            Ok ( Mono.MVar mid Mono.CNumber, c2 )

        IO.FlexSuper _ _ ->
            residualWithTaintC superTable revMemo var c1

        IO.FlexVar _ ->
            residualWithTaintC superTable revMemo var c1

        IO.RigidVar _ ->
            residualWithTaintC superTable revMemo var c1

        IO.RigidSuper IO.Number _ ->
            let
                ( mid, c2 ) =
                    residualIdC revMemo var c1
            in
            Ok ( Mono.MVar mid Mono.CNumber, c2 )

        IO.RigidSuper _ _ ->
            residualWithTaintC superTable revMemo var c1

        IO.Error ->
            Err (EngineBug "Error content encountered in zonkToMono")


residualWithTaintC : Dict.Dict Int IO.SuperType -> Array (Maybe TypeIds.MVarId) -> IO.Variable -> ZonkCtx -> Result Failure ( Mono.MonoType, ZonkCtx )
residualWithTaintC superTable revMemo var c0 =
    let
        ( mid, c1 ) =
            residualIdC revMemo var c0
    in
    case Dict.get (Engine.mvarIdKey mid) superTable of
        Just IO.Number ->
            Ok ( Mono.MVar mid Mono.CNumber, c1 )

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
                    Ok ( Mono.MVar mid Mono.CEcoValue, { c1 | ecoReads = var :: c1.ecoReads } )

                Nothing ->
                    Ok ( Mono.MVar mid Mono.CEcoValue, c1 )


residualIdC : Array (Maybe TypeIds.MVarId) -> IO.Variable -> ZonkCtx -> ( TypeIds.MVarId, ZonkCtx )
residualIdC revMemo var c =
    -- A2: point-indexed Array lookup (== the former `Dict.get pk`); a Nothing slot
    -- or out-of-range index means "not recorded" and mints a fresh id.
    case Maybe.andThen identity (Array.get (Engine.pointKey var) revMemo) of
        Just mid ->
            ( mid, c )

        Nothing ->
            ( c.next, { c | next = Id.succ c.next } )


zonkFlatC : Dict.Dict Int IO.SuperType -> Array (Maybe TypeIds.MVarId) -> IO.FlatType -> ZonkCtx -> Result Failure ( Mono.MonoType, ZonkCtx )
zonkFlatC superTable revMemo flat c0 =
    case flat of
        IO.App1 canonical name args ->
            case zonkListC superTable revMemo args c0 of
                Err e ->
                    Err e

                Ok ( mArgs, c1 ) ->
                    Ok (classifyAppC canonical name mArgs c1)

        IO.Fun1 a b ->
            case zonkToMonoC superTable revMemo a c0 of
                Err e ->
                    Err e

                Ok ( ma, c1 ) ->
                    case zonkToMonoC superTable revMemo b c1 of
                        Err e ->
                            Err e

                        Ok ( mb, c2 ) ->
                            Ok (consC (Mono.mFunction Mono.LTop [ ma ] mb) c2)

        IO.FunL a b setVar ->
            case zonkToMonoC superTable revMemo a c0 of
                Err e ->
                    Err e

                Ok ( ma, c1 ) ->
                    case zonkToMonoC superTable revMemo b c1 of
                        Err e ->
                            Err e

                        Ok ( mb, c2 ) ->
                            let
                                ( anno, c3 ) =
                                    zonkSetSlot ma mb setVar c2
                            in
                            Ok (consC (Mono.mFunction anno [ ma ] mb) c3)

        IO.LambdaSet1 _ ->
            -- LSS_007: a LambdaSet1 only ever lives inside a FunL set slot,
            -- which is consumed by the FunL arm — reaching here is a bug.
            Err (EngineBug "LambdaSet1 outside an arrow slot in zonkFlatC")

        IO.EmptyRecord1 ->
            Ok (consC (Mono.mRecord Dict.empty) c0)

        IO.Record1 fields ext ->
            case zonkRecordExtC superTable revMemo ext c0 of
                Err e ->
                    Err e

                Ok ( baseFields, c1 ) ->
                    zonkRecordFieldsC superTable revMemo (Dict.toList fields) baseFields c1

        IO.Unit1 ->
            Ok ( Mono.MUnit, c0 )

        IO.Tuple1 a b rest ->
            case zonkToMonoC superTable revMemo a c0 of
                Err e ->
                    Err e

                Ok ( ma, c1 ) ->
                    case zonkToMonoC superTable revMemo b c1 of
                        Err e ->
                            Err e

                        Ok ( mb, c2 ) ->
                            case zonkListC superTable revMemo rest c2 of
                                Err e ->
                                    Err e

                                Ok ( mRest, c3 ) ->
                                    Ok (consC (Mono.mTuple (ma :: mb :: mRest)) c3)


{-| Read a set slot back to an annotation. THE only producer of `LSet`. Runs
at item quiescence (zonk is the commit point — MONO_028 discipline), so a set
is read only after every unification the item will ever do. `paramT`/`resultT`
are the already-zonked param/result of the arrow whose slot this is — the
demanded instantiation LSS_019's grounding keys on. Policy:

  - unresolved slot (FlexVar) -> LTop (unknown, NOT empty — an empty claim
    would license consumers to treat the arrow as dead)
  - LsTop -> LTop (widened / kernel-facing)
  - LsMembers members -> under `lss.groundStandalones`, provisional `g|`/`c|`
    members first ground to `g|<global>|<widened-arrow-typeKey>` when the
    arrow is residual-free (LSS_019; deferral keeps the provisional id) —
    then LSet members, the store list by pointer (ascending by construction),
    unless |members| > maxSetSize -> LTop (counted in widenedBySize +
    widenedSizeHist; the cap applies to the REWRITTEN list — plan §3.2.3)

Ground ids written back into slots by a demand encode (`monoTypeToVarC`)
pass through the rewrite untouched (not in `provisionalStandalone`), so
zonk∘encode∘zonk is idempotent — the stability LSS_010's finite-lattice
argument needs.

-}
zonkSetSlot : Mono.MonoType -> Mono.MonoType -> IO.Variable -> ZonkCtx -> ( Mono.LambdaSetAnno, ZonkCtx )
zonkSetSlot paramT resultT setVar c0 =
    let
        ( store1, desc ) =
            UF.get setVar c0.store

        c1 =
            { c0 | store = store1 }
    in
    case desc.content of
        IO.Structure (IO.LambdaSet1 IO.LsTop) ->
            ( Mono.LTop, bumpZonkAcc Nothing c1 )

        IO.Structure (IO.LambdaSet1 (IO.LsMembers members0)) ->
            case c1.lss of
                Just acc0 ->
                    let
                        ( members, c2 ) =
                            if acc0.groundStandalones then
                                groundMembersC paramT resultT members0 c1

                            else
                                ( members0, c1 )

                        size =
                            List.length members
                    in
                    if size > acc0.maxSetSize then
                        ( Mono.LTop, bumpWidenedAcc size c2 )

                    else
                        -- Phase 2: IDENTITY — the store list IS the LSet
                        -- payload (ascending by construction; was Dict.keys).
                        ( Mono.LSet members, bumpZonkAcc (Just size) c2 )

                Nothing ->
                    -- A FunL zonked outside an lss-enabled wrapper (e.g. a
                    -- direct zonkToMonoC caller): sound fallback.
                    ( Mono.LTop, c1 )

        _ ->
            -- FlexVar residual: no information — LTop, never empty.
            ( Mono.LTop, bumpZonkAcc Nothing c1 )


{-| LSS_019: run the grounding rewrite against the ctx-threaded member table,
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


zonkListC : Dict.Dict Int IO.SuperType -> Array (Maybe TypeIds.MVarId) -> List IO.Variable -> ZonkCtx -> Result Failure ( List Mono.MonoType, ZonkCtx )
zonkListC superTable revMemo vars c0 =
    case vars of
        [] ->
            Ok ( [], c0 )

        v :: rest ->
            case zonkToMonoC superTable revMemo v c0 of
                Err e ->
                    Err e

                Ok ( m, c1 ) ->
                    case zonkListC superTable revMemo rest c1 of
                        Err e ->
                            Err e

                        Ok ( ms, c2 ) ->
                            Ok ( m :: ms, c2 )


zonkRecordFieldsC : Dict.Dict Int IO.SuperType -> Array (Maybe TypeIds.MVarId) -> List ( String, IO.Variable ) -> Dict.Dict String Mono.MonoType -> ZonkCtx -> Result Failure ( Mono.MonoType, ZonkCtx )
zonkRecordFieldsC superTable revMemo fields base c0 =
    case fields of
        [] ->
            Ok (consC (Mono.mRecord base) c0)

        ( k, p ) :: rest ->
            case zonkToMonoC superTable revMemo p c0 of
                Err e ->
                    Err e

                Ok ( v, c1 ) ->
                    zonkRecordFieldsC superTable revMemo rest (Dict.insert k v base) c1


{-| Extract the base-field dict from a record extension tail. -}
zonkRecordExtC : Dict.Dict Int IO.SuperType -> Array (Maybe TypeIds.MVarId) -> IO.Variable -> ZonkCtx -> Result Failure ( Dict.Dict String Mono.MonoType, ZonkCtx )
zonkRecordExtC superTable revMemo ext c0 =
    case zonkToMonoC superTable revMemo ext c0 of
        Err e ->
            Err e

        Ok ( mt, c1 ) ->
            case mt of
                Mono.MRecord _ fields ->
                    Ok ( fields, c1 )

                _ ->
                    -- Open extension resolved to a var/other: no base fields.
                    Ok ( Dict.empty, c1 )


{-| `classifyApp` hash-consed against a `ZonkCtx` (K6). Leaves (`MInt`, …) fall
through `Intern.hashCons` untouched, so this costs one branch on the primitive
arms.
-}
classifyAppC : IO.Canonical -> String -> List Mono.MonoType -> ZonkCtx -> ( Mono.MonoType, ZonkCtx )
classifyAppC canonical name args c =
    consC (classifyApp canonical name args) c


classifyApp : IO.Canonical -> String -> List Mono.MonoType -> Mono.MonoType
classifyApp canonical name args =
    let
        isElmCore =
            case canonical of
                IO.Canonical ( "elm", "core" ) _ ->
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
classifyDirect : Can.Type TypeIds.MVarId -> Step Mono.MonoType
classifyDirect canType s =
    classifyGo s Dict.empty canType


classifyGo : Engine.S -> Dict.Dict Int Mono.MonoType -> Can.Type TypeIds.MVarId -> Result Failure ( Mono.MonoType, Engine.S )
classifyGo s aliasSubst canType =
    case canType of
        Can.TVar mvarId ->
            let
                key =
                    Engine.mvarIdKey mvarId
            in
            case Dict.get key aliasSubst of
                Just mono ->
                    Ok ( mono, s )

                Nothing ->
                    case Dict.get key s.memo of
                        Just pt ->
                            -- Demand-concretized this item: read the bound Point back.
                            -- Threads S (zonk can allocate a residual id).
                            zonkToMono pt s

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
                                    Ok ( Mono.MVar mvarId Mono.CEcoValue, { s | itemAux = { aux0 | ecoResidualKeyReads = key :: aux0.ecoResidualKeyReads } } )

                                residual ->
                                    Ok ( residual, s )

        Can.TLambda from to ->
            case classifyGo s aliasSubst from of
                Err e ->
                    Err e

                Ok ( mFrom, s1 ) ->
                    case classifyGo s1 aliasSubst to of
                        Err e ->
                            Err e

                        Ok ( mTo, s2 ) ->
                            -- One arrow per MFunction, mirroring zonkFlat's Fun1 arm
                            -- (GlobalOpt flattens later per GOPT_016). Storeless
                            -- classification stamps LTop (sound-but-imprecise;
                            -- fast paths gate on signature triviality in M2).
                            Ok (Engine.consS (Mono.mFunction Mono.LTop [ mFrom ] mTo) s2)

        Can.TType canonical name args ->
            case classifyList s aliasSubst args of
                Err e ->
                    Err e

                Ok ( mArgs, s1 ) ->
                    Ok (Engine.consS (classifyApp canonical name mArgs) s1)

        Can.TRecord fields maybeExtension ->
            case classifyRecordExt s aliasSubst maybeExtension of
                Err e ->
                    Err e

                Ok ( baseFields, s1 ) ->
                    case classifyRecordFields s1 aliasSubst (Dict.toList fields) baseFields of
                        Err e ->
                            Err e

                        Ok ( allFields, s2 ) ->
                            Ok (Engine.consS (Mono.mRecord allFields) s2)

        Can.TUnit ->
            Ok ( Mono.MUnit, s )

        Can.TTuple a b rest ->
            case classifyGo s aliasSubst a of
                Err e ->
                    Err e

                Ok ( ma, s1 ) ->
                    case classifyGo s1 aliasSubst b of
                        Err e ->
                            Err e

                        Ok ( mb, s2 ) ->
                            case classifyList s2 aliasSubst rest of
                                Err e ->
                                    Err e

                                Ok ( mRest, s3 ) ->
                                    Ok (Engine.consS (Mono.mTuple (ma :: mb :: mRest)) s3)

        Can.TAlias _ _ _ (Can.Filled inner) ->
            classifyGo s aliasSubst inner

        Can.TAlias _ _ args (Can.Holey inner) ->
            -- Alias args are classified in the OUTER scope (mirrors
            -- Zonk.canTypeToMonoWith's Holey arm), then the body under the extended
            -- substitution.
            case classifyAliasArgs s aliasSubst args aliasSubst of
                Err e ->
                    Err e

                Ok ( newSubst, s1 ) ->
                    classifyGo s1 newSubst inner


classifyList : Engine.S -> Dict.Dict Int Mono.MonoType -> List (Can.Type TypeIds.MVarId) -> Result Failure ( List Mono.MonoType, Engine.S )
classifyList s aliasSubst types =
    case types of
        [] ->
            Ok ( [], s )

        t :: rest ->
            case classifyGo s aliasSubst t of
                Err e ->
                    Err e

                Ok ( m, s1 ) ->
                    case classifyList s1 aliasSubst rest of
                        Err e ->
                            Err e

                        Ok ( ms, s2 ) ->
                            Ok ( m :: ms, s2 )


classifyAliasArgs : Engine.S -> Dict.Dict Int Mono.MonoType -> List ( TypeIds.MVarId, Can.Type TypeIds.MVarId ) -> Dict.Dict Int Mono.MonoType -> Result Failure ( Dict.Dict Int Mono.MonoType, Engine.S )
classifyAliasArgs s outerSubst args acc =
    case args of
        [] ->
            Ok ( acc, s )

        ( paramId, t ) :: rest ->
            case classifyGo s outerSubst t of
                Err e ->
                    Err e

                Ok ( mt, s1 ) ->
                    classifyAliasArgs s1 outerSubst rest (Dict.insert (Engine.mvarIdKey paramId) mt acc)


classifyRecordExt : Engine.S -> Dict.Dict Int Mono.MonoType -> Maybe TypeIds.MVarId -> Result Failure ( Dict.Dict String Mono.MonoType, Engine.S )
classifyRecordExt s aliasSubst maybeExtension =
    case maybeExtension of
        Nothing ->
            Ok ( Dict.empty, s )

        Just extVar ->
            case classifyGo s aliasSubst (Can.TVar extVar) of
                Err e ->
                    Err e

                Ok ( mt, s1 ) ->
                    case mt of
                        Mono.MRecord _ baseFields ->
                            Ok ( baseFields, s1 )

                        _ ->
                            -- Open extension resolved to a var/other: no base fields
                            -- (matches zonkRecordExt).
                            Ok ( Dict.empty, s1 )


classifyRecordFields : Engine.S -> Dict.Dict Int Mono.MonoType -> List ( String, Can.FieldType TypeIds.MVarId ) -> Dict.Dict String Mono.MonoType -> Result Failure ( Dict.Dict String Mono.MonoType, Engine.S )
classifyRecordFields s aliasSubst fields base =
    case fields of
        [] ->
            Ok ( base, s )

        ( k, Can.FieldType _ t ) :: rest ->
            case classifyGo s aliasSubst t of
                Err e ->
                    Err e

                Ok ( mt, s1 ) ->
                    classifyRecordFields s1 aliasSubst rest (Dict.insert k mt base)


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
        Just IO.Number ->
            Mono.MVar mvarId Mono.CNumber

        _ ->
            Mono.MVar mvarId Mono.CEcoValue
