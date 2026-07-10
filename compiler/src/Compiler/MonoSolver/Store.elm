module Compiler.MonoSolver.Store exposing
    ( classifyDirect
    , loadType
    , loadTypeIsolated
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
    }


loadType : Can.Type TypeIds.MVarId -> Step IO.Variable
loadType canType =
    \s ->
        let
            ( v, c ) =
                loadTypeC s.env.superStatic canType { store = s.store, memo = s.memo, revMemo = s.revMemo }
        in
        Ok ( v, { s | store = c.store, memo = c.memo, revMemo = c.revMemo } )


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
                loadTypeC s.env.superStatic canType { store = s.store, memo = Dict.empty, revMemo = s.revMemo }
        in
        Ok ( v, { s | store = c.store, revMemo = c.revMemo } )


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
real home, which is needed for `MCustom`.
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
                monoTypeToVarC monoType s.store
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


monoTypeToVarC : Mono.MonoType -> IO.State -> ( IO.Variable, IO.State )
monoTypeToVarC monoType st =
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

        Mono.MList inner ->
            let
                ( p, st1 ) =
                    monoTypeToVarC inner st
            in
            structS (IO.App1 ModuleName.list "List" [ p ]) st1

        Mono.MTuple elems ->
            case elems of
                a :: b :: rest ->
                    let
                        ( pa, st1 ) =
                            monoTypeToVarC a st

                        ( pb, st2 ) =
                            monoTypeToVarC b st1

                        ( pRest, st3 ) =
                            monoListToVarC rest st2
                    in
                    structS (IO.Tuple1 pa pb pRest) st3

                _ ->
                    -- Degenerate tuple; encode as a fresh var rather than crash.
                    freshVarS (IO.FlexVar Nothing) st

        Mono.MRecord fields ->
            let
                ( pFields, st1 ) =
                    recordFieldPointsC (Dict.toList fields) st

                ( ext, st2 ) =
                    structS IO.EmptyRecord1 st1
            in
            structS (IO.Record1 pFields ext) st2

        Mono.MCustom home name args ->
            let
                ( pArgs, st1 ) =
                    monoListToVarC args st
            in
            structS (IO.App1 home name pArgs) st1

        Mono.MFunction args result ->
            -- Fold args right-to-left into nested Fun1 (one arg per arrow).
            let
                ( pResult, st1 ) =
                    monoTypeToVarC result st
            in
            List.foldl
                (\argType ( accPoint, stA ) ->
                    let
                        ( pa, stA1 ) =
                            monoTypeToVarC argType stA
                    in
                    structS (IO.Fun1 pa accPoint) stA1
                )
                ( pResult, st1 )
                (List.reverse args)

        Mono.MVar _ Mono.CNumber ->
            freshVarS (IO.FlexSuper IO.Number Nothing) st

        Mono.MVar _ Mono.CEcoValue ->
            freshVarS (IO.FlexVar Nothing) st


monoListToVarC : List Mono.MonoType -> IO.State -> ( List IO.Variable, IO.State )
monoListToVarC types st =
    case types of
        [] ->
            ( [], st )

        t :: rest ->
            let
                ( p, st1 ) =
                    monoTypeToVarC t st

                ( ps, st2 ) =
                    monoListToVarC rest st1
            in
            ( p :: ps, st2 )


recordFieldPointsC : List ( String, Mono.MonoType ) -> IO.State -> ( Dict.Dict String IO.Variable, IO.State )
recordFieldPointsC fields st =
    List.foldl
        (\( k, t ) ( acc, stA ) ->
            let
                ( pt, stA1 ) =
                    monoTypeToVarC t stA
            in
            ( Dict.insert k pt acc, stA1 )
        )
        ( Dict.empty, st )
        fields


-- ====== UNIFY ======


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
                    Engine.fail (UnifyMismatch ("unify-fail " ++ errKind t1 ++ " /vs/ " ++ errKind t2))
        )
        (Engine.liftIO (Unify.unify v1 v2))



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
    }


zonkToMono : IO.Variable -> Step Mono.MonoType
zonkToMono var =
    \s ->
        case zonkToMonoC s.superTable s.revMemo var { store = s.store, next = s.nextMVarId } of
            Err e ->
                Err e

            Ok ( mt, c ) ->
                Ok ( mt, { s | store = c.store, nextMVarId = c.next } )


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
    Ok
        ( case Dict.get (Engine.mvarIdKey mid) superTable of
            Just IO.Number ->
                Mono.MVar mid Mono.CNumber

            _ ->
                Mono.MVar mid Mono.CEcoValue
        , c1
        )


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
                    Ok ( classifyApp canonical name mArgs, c1 )

        IO.Fun1 a b ->
            case zonkToMonoC superTable revMemo a c0 of
                Err e ->
                    Err e

                Ok ( ma, c1 ) ->
                    case zonkToMonoC superTable revMemo b c1 of
                        Err e ->
                            Err e

                        Ok ( mb, c2 ) ->
                            Ok ( Mono.MFunction [ ma ] mb, c2 )

        IO.EmptyRecord1 ->
            Ok ( Mono.MRecord Dict.empty, c0 )

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
                                    Ok ( Mono.MTuple (ma :: mb :: mRest), c3 )


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
            Ok ( Mono.MRecord base, c0 )

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
                Mono.MRecord fields ->
                    Ok ( fields, c1 )

                _ ->
                    -- Open extension resolved to a var/other: no base fields.
                    Ok ( Dict.empty, c1 )


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
                        Mono.MList inner

                    _ ->
                        Mono.MList Mono.MUnit

            _ ->
                Mono.MCustom canonical name args

    else
        Mono.MCustom canonical name args


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
                            Ok ( residualForVar mvarId s, s )

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
                            -- (GlobalOpt flattens later per GOPT_016).
                            Ok ( Mono.MFunction [ mFrom ] mTo, s2 )

        Can.TType canonical name args ->
            case classifyList s aliasSubst args of
                Err e ->
                    Err e

                Ok ( mArgs, s1 ) ->
                    Ok ( classifyApp canonical name mArgs, s1 )

        Can.TRecord fields maybeExtension ->
            case classifyRecordExt s aliasSubst maybeExtension of
                Err e ->
                    Err e

                Ok ( baseFields, s1 ) ->
                    case classifyRecordFields s1 aliasSubst (Dict.toList fields) baseFields of
                        Err e ->
                            Err e

                        Ok ( allFields, s2 ) ->
                            Ok ( Mono.MRecord allFields, s2 )

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
                                    Ok ( Mono.MTuple (ma :: mb :: mRest), s3 )

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
                        Mono.MRecord baseFields ->
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
