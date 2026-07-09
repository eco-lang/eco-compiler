module Compiler.MonoSolver.Store exposing
    ( loadType
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
import Compiler.Type.UnionFind as UF
import Compiler.Type.Unify as Unify
import Dict
import System.TypeCheck.IO as IO



-- ====== LOAD: Can.Type -> store Point ======


{-| Load a canonical type into the store, returning its root Point. Structural
recursion mirroring the real solver's `srcTypeToVar` minus pools; each distinct
MVarId is memoized to one Point so shared vars share a Point.
-}
loadType : Can.Type TypeIds.MVarId -> Step IO.Variable
loadType canType =
    case canType of
        Can.TVar mvarId ->
            loadVar mvarId

        Can.TLambda from to ->
            Engine.andThen
                (\pFrom ->
                    Engine.andThen
                        (\pTo -> struct (IO.Fun1 pFrom pTo))
                        (loadType to)
                )
                (loadType from)

        Can.TType canonical name args ->
            Engine.andThen
                (\pArgs -> struct (IO.App1 (normalizePrimHome canonical name) name pArgs))
                (Engine.traverse loadType args)

        Can.TRecord fields maybeExtension ->
            Engine.andThen
                (\pExt ->
                    Engine.andThen
                        (\pFields -> struct (IO.Record1 pFields pExt))
                        (loadRecordFields fields)
                )
                (loadRecordExt maybeExtension)

        Can.TUnit ->
            struct IO.Unit1

        Can.TTuple a b rest ->
            Engine.andThen
                (\pa ->
                    Engine.andThen
                        (\pb ->
                            Engine.andThen
                                (\pRest -> struct (IO.Tuple1 pa pb pRest))
                                (Engine.traverse loadType rest)
                        )
                        (loadType b)
                )
                (loadType a)

        Can.TAlias _ _ _ (Can.Filled inner) ->
            loadType inner

        Can.TAlias _ _ args (Can.Holey inner) ->
            -- Bind each alias parameter to its argument's loaded Point, load the
            -- body, then restore the memo (params are alias-local).
            Engine.andThen
                (\argPoints ->
                    withMemoBindings
                        (List.map2 (\( paramId, _ ) pt -> ( Engine.mvarIdKey paramId, pt )) args argPoints)
                        (loadType inner)
                )
                (Engine.traverse (\( _, argTy ) -> loadType argTy) args)


{-| Load or reuse the Point for a type variable, minting it with the super
recorded in the (growing) super table. Records both memo directions.
-}
loadVar : TypeIds.MVarId -> Step IO.Variable
loadVar mvarId =
    let
        key =
            Engine.mvarIdKey mvarId
    in
    Engine.andThen
        (\memo ->
            case Dict.get key memo of
                Just pt ->
                    Engine.succeed pt

                Nothing ->
                    -- Mint from the STATIC super truth only. The harvested Join-R
                    -- taint must NOT force a super here: the same annotation var is
                    -- instantiated at a different type in every specialization (e.g.
                    -- `k : a -> b -> a` at `b := num` in one item and `b := num->num`
                    -- in another), and a taint-forced `FlexSuper Number` would refuse
                    -- to unify with the function. Taint is consulted at ZONK time
                    -- (residual classification) instead, like the original engine's
                    -- `refreshConstraints`.
                    Engine.andThen
                        (\superStatic ->
                            let
                                content =
                                    case Dict.get key superStatic of
                                        Just superType ->
                                            IO.FlexSuper superType Nothing

                                        Nothing ->
                                            IO.FlexVar Nothing
                            in
                            Engine.andThen
                                (\pt -> Engine.map (\_ -> pt) (recordVar key mvarId pt))
                                (Engine.freshVar content)
                        )
                        (Engine.getS .superStatic)
        )
        (Engine.getS .memo)


recordVar : Int -> TypeIds.MVarId -> IO.Variable -> Step ()
recordVar key mvarId pt =
    Engine.modifyS
        (\s ->
            { s
                | memo = Dict.insert key pt s.memo
                , revMemo =
                    let
                        pk =
                            Engine.pointKey pt
                    in
                    if Dict.member pk s.revMemo then
                        s.revMemo

                    else
                        Dict.insert pk mvarId s.revMemo
            }
        )


loadRecordExt : Maybe TypeIds.MVarId -> Step IO.Variable
loadRecordExt maybeExtension =
    case maybeExtension of
        Just extMvarId ->
            loadVar extMvarId

        Nothing ->
            struct IO.EmptyRecord1


loadRecordFields : Dict.Dict String (Can.FieldType TypeIds.MVarId) -> Step (Dict.Dict String IO.Variable)
loadRecordFields fields =
    Engine.foldlS
        (\( k, Can.FieldType _ t ) acc ->
            Engine.map (\pt -> Dict.insert k pt acc) (loadType t)
        )
        Dict.empty
        (Dict.toList fields)


struct : IO.FlatType -> Step IO.Variable
struct flat =
    Engine.freshVar (IO.Structure flat)


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


{-| Run a step with extra memo bindings in scope, restoring the prior bindings
for exactly those keys afterward.
-}
withMemoBindings : List ( Int, IO.Variable ) -> Step a -> Step a
withMemoBindings bindings inner =
    \s0 ->
        let
            keys =
                List.map Tuple.first bindings

            saved =
                List.map (\k -> ( k, Dict.get k s0.memo )) keys

            s1 =
                { s0 | memo = List.foldl (\( k, v ) m -> Dict.insert k v m) s0.memo bindings }
        in
        case inner s1 of
            Err e ->
                Err e

            Ok ( a, s2 ) ->
                let
                    restored =
                        List.foldl
                            (\( k, mv ) m ->
                                case mv of
                                    Just v ->
                                        Dict.insert k v m

                                    Nothing ->
                                        Dict.remove k m
                            )
                            s2.memo
                            saved
                in
                Ok ( a, { s2 | memo = restored } )



-- ====== ENCODE: MonoType -> concrete store Point ======


{-| Encode a demanded MonoType as concrete store structure, the dual of the
`zonkToMono` classification. Residual `MVar`s become fresh flex vars (a demand
carrying a var is only meaningful in M2).
-}
monoTypeToVar : Mono.MonoType -> Step IO.Variable
monoTypeToVar monoType =
    case monoType of
        Mono.MInt ->
            struct (IO.App1 ModuleName.basics "Int" [])

        Mono.MFloat ->
            struct (IO.App1 ModuleName.basics "Float" [])

        Mono.MBool ->
            struct (IO.App1 ModuleName.basics "Bool" [])

        Mono.MChar ->
            struct (IO.App1 ModuleName.char "Char" [])

        Mono.MString ->
            struct (IO.App1 ModuleName.string "String" [])

        Mono.MUnit ->
            struct IO.Unit1

        Mono.MList inner ->
            Engine.andThen (\p -> struct (IO.App1 ModuleName.list "List" [ p ])) (monoTypeToVar inner)

        Mono.MTuple elems ->
            case elems of
                a :: b :: rest ->
                    Engine.andThen
                        (\pa ->
                            Engine.andThen
                                (\pb ->
                                    Engine.andThen
                                        (\pRest -> struct (IO.Tuple1 pa pb pRest))
                                        (Engine.traverse monoTypeToVar rest)
                                )
                                (monoTypeToVar b)
                        )
                        (monoTypeToVar a)

                _ ->
                    -- Degenerate tuple; encode as a fresh var rather than crash.
                    Engine.freshVar (IO.FlexVar Nothing)

        Mono.MRecord fields ->
            Engine.andThen
                (\pFields ->
                    Engine.andThen
                        (\ext -> struct (IO.Record1 pFields ext))
                        (struct IO.EmptyRecord1)
                )
                (recordFieldPoints (Dict.toList fields))

        Mono.MCustom home name args ->
            Engine.andThen (\pArgs -> struct (IO.App1 home name pArgs)) (Engine.traverse monoTypeToVar args)

        Mono.MFunction args result ->
            -- Fold args right-to-left into nested Fun1 (one arg per arrow).
            Engine.andThen
                (\pResult ->
                    Engine.foldlS
                        (\argType accPoint -> Engine.andThen (\pa -> struct (IO.Fun1 pa accPoint)) (monoTypeToVar argType))
                        pResult
                        (List.reverse args)
                )
                (monoTypeToVar result)

        Mono.MVar _ Mono.CNumber ->
            Engine.freshVar (IO.FlexSuper IO.Number Nothing)

        Mono.MVar _ Mono.CEcoValue ->
            Engine.freshVar (IO.FlexVar Nothing)


recordFieldPoints : List ( String, Mono.MonoType ) -> Step (Dict.Dict String IO.Variable)
recordFieldPoints fields =
    Engine.foldlS
        (\( k, t ) acc -> Engine.map (\pt -> Dict.insert k pt acc) (monoTypeToVar t))
        Dict.empty
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


{-| Read a Point back to a MonoType (post-order over union-find content).
Residuals stamp from the live content; ids come from `revMemo`.
-}
zonkToMono : IO.Variable -> Step Mono.MonoType
zonkToMono var =
    Engine.andThen
        (\desc ->
            case desc.content of
                IO.Structure flat ->
                    zonkFlat flat

                IO.Alias _ _ _ real ->
                    zonkToMono real

                IO.FlexSuper IO.Number _ ->
                    Engine.map (\mid -> Mono.MVar mid Mono.CNumber) (residualId var)

                IO.FlexSuper _ _ ->
                    residualWithTaint var

                IO.FlexVar _ ->
                    residualWithTaint var

                IO.RigidVar _ ->
                    residualWithTaint var

                IO.RigidSuper IO.Number _ ->
                    Engine.map (\mid -> Mono.MVar mid Mono.CNumber) (residualId var)

                IO.RigidSuper _ _ ->
                    residualWithTaint var

                IO.Error ->
                    Engine.fail (EngineBug "Error content encountered in zonkToMono")
        )
        (Engine.liftIO (UF.get var))


zonkFlat : IO.FlatType -> Step Mono.MonoType
zonkFlat flat =
    case flat of
        IO.App1 canonical name args ->
            Engine.map (classifyApp canonical name) (Engine.traverse zonkToMono args)

        IO.Fun1 a b ->
            Engine.map2 (\ma mb -> Mono.MFunction [ ma ] mb) (zonkToMono a) (zonkToMono b)

        IO.EmptyRecord1 ->
            Engine.succeed (Mono.MRecord Dict.empty)

        IO.Record1 fields ext ->
            Engine.andThen
                (\baseFields ->
                    Engine.map
                        (\fieldPairs -> Mono.MRecord (List.foldl (\( k, v ) acc -> Dict.insert k v acc) baseFields fieldPairs))
                        (Engine.traverse (\( k, p ) -> Engine.map (\v -> ( k, v )) (zonkToMono p)) (Dict.toList fields))
                )
                (zonkRecordExt ext)

        IO.Unit1 ->
            Engine.succeed Mono.MUnit

        IO.Tuple1 a b rest ->
            Engine.andThen
                (\ma ->
                    Engine.andThen
                        (\mb -> Engine.map (\mRest -> Mono.MTuple (ma :: mb :: mRest)) (Engine.traverse zonkToMono rest))
                        (zonkToMono b)
                )
                (zonkToMono a)


{-| Extract the base-field dict from a record extension tail.
-}
zonkRecordExt : IO.Variable -> Step (Dict.Dict String Mono.MonoType)
zonkRecordExt ext =
    Engine.andThen
        (\mt ->
            case mt of
                Mono.MRecord fields ->
                    Engine.succeed fields

                _ ->
                    -- Open extension resolved to a var/other: no base fields.
                    Engine.succeed Dict.empty
        )
        (zonkToMono ext)


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


{-| Classify a non-Number residual, consulting the harvested Join-R taint: an
unbound var whose id was number-tainted by ANOTHER specialization stamps as
`CNumber` (keys as Int; Prune closes it to MInt) — the zonk-time analogue of the
original engine's `refreshConstraints`. Bound structure never reaches here, so
the taint can re-stamp residuals but can never block a unification.
-}
residualWithTaint : IO.Variable -> Step Mono.MonoType
residualWithTaint var =
    Engine.andThen
        (\mid ->
            Engine.map
                (\superTable ->
                    case Dict.get (Engine.mvarIdKey mid) superTable of
                        Just IO.Number ->
                            Mono.MVar mid Mono.CNumber

                        _ ->
                            Mono.MVar mid Mono.CEcoValue
                )
                (Engine.getS .superTable)
        )
        (residualId var)


{-| The MVarId to stamp on a residual: the first MVarId that minted this Point,
or a fresh engine id if the Point came from internal unification. Because
`toComparableMonoType` drops the id, this never affects spec keys; it only
matters for `CEcoValue` residuals surviving to the final graph.
-}
residualId : IO.Variable -> Step TypeIds.MVarId
residualId var =
    Engine.andThen
        (\rev ->
            case Dict.get (Engine.pointKey var) rev of
                Just mid ->
                    Engine.succeed mid

                Nothing ->
                    allocFreshMVarId
        )
        (Engine.getS .revMemo)


allocFreshMVarId : Step TypeIds.MVarId
allocFreshMVarId =
    \s -> Ok ( s.nextMVarId, { s | nextMVarId = Id.succ s.nextMVarId } )
