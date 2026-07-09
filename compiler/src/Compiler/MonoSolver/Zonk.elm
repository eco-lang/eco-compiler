module Compiler.MonoSolver.Zonk exposing (canTypeToMono, canTypeToMonoWith)

{-| Convert a `Can.Type MVarId` to a `Mono.MonoType`.

For M1 (monomorphic globals) the original engine's substitution is empty, so a
node's monomorphized type is exactly this pure classification of its
`meta.tipe` — a faithful reimplementation of `TypeSubst.applySubstPure` with an
empty substitution, which the A/B gate verifies against the original engine.

Number/comparable residuals are stamped from the `superVars` table (solver
truth exported by `AssignMVarIds`), never eagerly defaulted — the shared Prune
close discharges `MVar _ CNumber → MInt` at the end (MONO_028). The internal
`subst` accumulator carries only alias parameters (the `Holey` case), matching
`applySubstPure`'s alias handling.

In M2 this gains a store-based `zonkToMono` sibling for polymorphic demand
propagation; M1 needs only the store-free classification.

@docs canTypeToMono

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeIds as TypeIds
import Compiler.Data.Id as Id
import Dict exposing (Dict)
import System.TypeCheck.IO as IO


{-| Classify a canonical type into a monomorphized type. `superVars` maps an
MVarId (by `Id.toComparable`) to its super constraint; a var with `Number`
becomes a `CNumber` residual, anything else a `CEcoValue` residual.
-}
canTypeToMono : Dict Int IO.SuperType -> Can.Type TypeIds.MVarId -> Mono.MonoType
canTypeToMono superVars canType =
    canTypeToMonoWith superVars Dict.empty canType


canTypeToMonoWith : Dict Int IO.SuperType -> Dict Int Mono.MonoType -> Can.Type TypeIds.MVarId -> Mono.MonoType
canTypeToMonoWith superVars subst canType =
    case canType of
        Can.TVar mvarId ->
            case Dict.get (Id.toComparable mvarId) subst of
                Just monoType ->
                    monoType

                Nothing ->
                    case Dict.get (Id.toComparable mvarId) superVars of
                        Just IO.Number ->
                            Mono.MVar mvarId Mono.CNumber

                        _ ->
                            Mono.MVar mvarId Mono.CEcoValue

        Can.TLambda from to ->
            lambdaChain superVars subst [ from ] to

        Can.TType canonical name args ->
            let
                monoArgs =
                    List.map (canTypeToMonoWith superVars subst) args

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
                        case monoArgs of
                            [ inner ] ->
                                Mono.MList inner

                            _ ->
                                Mono.MList Mono.MUnit

                    _ ->
                        Mono.MCustom canonical name monoArgs

            else
                Mono.MCustom canonical name monoArgs

        Can.TRecord fields maybeExtension ->
            let
                baseFields =
                    case maybeExtension of
                        Just extMvarId ->
                            case Dict.get (Id.toComparable extMvarId) subst of
                                Just (Mono.MRecord baseFieldsDict) ->
                                    baseFieldsDict

                                _ ->
                                    Dict.empty

                        Nothing ->
                            Dict.empty

                monoFields =
                    Dict.foldl
                        (\k (Can.FieldType _ t) acc ->
                            Dict.insert k (canTypeToMonoWith superVars subst t) acc
                        )
                        baseFields
                        fields
            in
            Mono.MRecord monoFields

        Can.TTuple a b rest ->
            Mono.MTuple (List.map (canTypeToMonoWith superVars subst) (a :: b :: rest))

        Can.TUnit ->
            Mono.MUnit

        Can.TAlias _ _ _ (Can.Filled inner) ->
            canTypeToMonoWith superVars subst inner

        Can.TAlias _ _ args (Can.Holey inner) ->
            let
                newSubst =
                    List.foldl
                        (\( paramId, t ) s ->
                            Dict.insert (Id.toComparable paramId) (canTypeToMonoWith superVars subst t) s
                        )
                        subst
                        args
            in
            canTypeToMonoWith superVars newSubst inner


{-| Collect a run of `TLambda`s into a nested one-arg-per-arrow `MFunction`,
exactly as `TypeSubst.applySubstLambdaChain` does (a -> b -> c becomes
`MFunction [a] (MFunction [b] c)`; GlobalOpt flattens later per GOPT_016).
-}
lambdaChain : Dict Int IO.SuperType -> Dict Int Mono.MonoType -> List (Can.Type TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Mono.MonoType
lambdaChain superVars subst argsAcc to =
    case to of
        Can.TLambda from innerTo ->
            lambdaChain superVars subst (from :: argsAcc) innerTo

        _ ->
            List.foldl
                (\argType acc ->
                    Mono.MFunction [ canTypeToMonoWith superVars subst argType ] acc
                )
                (canTypeToMonoWith superVars subst to)
                argsAcc
