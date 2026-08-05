module Compiler.MonoSolver.Zonk exposing (canTypeToMono, canTypeToMonoI, canTypeToMonoWith, canTypeToMonoWithI)

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

**K6 (plan §15).** The `…I` forms thread an `Intern` table so every composite is
hash-consed at construction, exactly as `TypeSubst.applySubstPureI` is on the
subst side. The bare forms are wrappers over `Intern.disabled`, for callers with
no state to thread — sound (sharing is never required for correctness), and
cheaper than handing them a throwaway table that would allocate an insert per
node.

@docs canTypeToMono, canTypeToMonoI, canTypeToMonoWith, canTypeToMonoWithI

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Intern as Intern exposing (Intern)
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
    Tuple.first (canTypeToMonoWithI superVars Dict.empty canType Intern.disabled)


{-| `canTypeToMono` threading the K6 hash-cons table.
-}
canTypeToMonoI : Dict Int IO.SuperType -> Can.Type TypeIds.MVarId -> Intern -> ( Mono.MonoType, Intern )
canTypeToMonoI superVars canType intern =
    canTypeToMonoWithI superVars Dict.empty canType intern


canTypeToMonoWith : Dict Int IO.SuperType -> Dict Int Mono.MonoType -> Can.Type TypeIds.MVarId -> Mono.MonoType
canTypeToMonoWith superVars subst canType =
    Tuple.first (canTypeToMonoWithI superVars subst canType Intern.disabled)


canTypeToMonoWithI : Dict Int IO.SuperType -> Dict Int Mono.MonoType -> Can.Type TypeIds.MVarId -> Intern -> ( Mono.MonoType, Intern )
canTypeToMonoWithI superVars subst canType intern0 =
    case canType of
        Can.TVar mvarId ->
            case Dict.get (Id.toComparable mvarId) subst of
                Just monoType ->
                    ( monoType, intern0 )

                Nothing ->
                    case Dict.get (Id.toComparable mvarId) superVars of
                        Just IO.Number ->
                            ( Mono.MVar mvarId Mono.CNumber, intern0 )

                        _ ->
                            ( Mono.MVar mvarId Mono.CEcoValue, intern0 )

        Can.TLambda from to ->
            lambdaChain superVars subst [ from ] to intern0

        Can.TType canonical name args ->
            let
                ( monoArgs, intern1 ) =
                    listToMono superVars subst args intern0

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
                        ( Mono.MInt, intern1 )

                    "Float" ->
                        ( Mono.MFloat, intern1 )

                    "Bool" ->
                        ( Mono.MBool, intern1 )

                    "Char" ->
                        ( Mono.MChar, intern1 )

                    "String" ->
                        ( Mono.MString, intern1 )

                    "List" ->
                        case monoArgs of
                            [ inner ] ->
                                Intern.hashCons (Mono.mList inner) intern1

                            _ ->
                                Intern.hashCons (Mono.mList Mono.MUnit) intern1

                    _ ->
                        Intern.hashCons (Mono.mCustom canonical name monoArgs) intern1

            else
                Intern.hashCons (Mono.mCustom canonical name monoArgs) intern1

        Can.TRecord fields maybeExtension ->
            let
                baseFields =
                    case maybeExtension of
                        Just extMvarId ->
                            case Dict.get (Id.toComparable extMvarId) subst of
                                Just (Mono.MRecord _ baseFieldsDict) ->
                                    baseFieldsDict

                                _ ->
                                    Dict.empty

                        Nothing ->
                            Dict.empty

                ( monoFields, intern1 ) =
                    Dict.foldl
                        (\k (Can.FieldType _ t) ( acc, i0 ) ->
                            let
                                ( mt, i1 ) =
                                    canTypeToMonoWithI superVars subst t i0
                            in
                            ( Dict.insert k mt acc, i1 )
                        )
                        ( baseFields, intern0 )
                        fields
            in
            Intern.hashCons (Mono.mRecord monoFields) intern1

        Can.TTuple a b rest ->
            let
                ( monoElems, intern1 ) =
                    listToMono superVars subst (a :: b :: rest) intern0
            in
            Intern.hashCons (Mono.mTuple monoElems) intern1

        Can.TUnit ->
            ( Mono.MUnit, intern0 )

        Can.TAlias _ _ _ (Can.Filled inner) ->
            canTypeToMonoWithI superVars subst inner intern0

        Can.TAlias _ _ args (Can.Holey inner) ->
            let
                ( newSubst, intern1 ) =
                    List.foldl
                        (\( paramId, t ) ( acc, i0 ) ->
                            let
                                ( mt, i1 ) =
                                    canTypeToMonoWithI superVars subst t i0
                            in
                            ( Dict.insert (Id.toComparable paramId) mt acc, i1 )
                        )
                        ( subst, intern0 )
                        args
            in
            canTypeToMonoWithI superVars newSubst inner intern1


{-| `List.map (canTypeToMonoWith …)` threading the table — same element order,
same left-to-right conversion order.
-}
listToMono : Dict Int IO.SuperType -> Dict Int Mono.MonoType -> List (Can.Type TypeIds.MVarId) -> Intern -> ( List Mono.MonoType, Intern )
listToMono superVars subst types intern0 =
    case types of
        [] ->
            ( [], intern0 )

        t :: rest ->
            let
                ( mt, intern1 ) =
                    canTypeToMonoWithI superVars subst t intern0

                ( mRest, intern2 ) =
                    listToMono superVars subst rest intern1
            in
            ( mt :: mRest, intern2 )


{-| Collect a run of `TLambda`s into a nested one-arg-per-arrow `Mono.mFunction`,
exactly as `TypeSubst.applySubstLambdaChain` does (a -> b -> c becomes
`Mono.mFunction [a] (Mono.mFunction [b] c)`; GlobalOpt flattens later per GOPT_016).
-}
lambdaChain : Dict Int IO.SuperType -> Dict Int Mono.MonoType -> List (Can.Type TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Intern -> ( Mono.MonoType, Intern )
lambdaChain superVars subst argsAcc to intern0 =
    case to of
        Can.TLambda from innerTo ->
            lambdaChain superVars subst (from :: argsAcc) innerTo intern0

        _ ->
            let
                ( resultType, intern1 ) =
                    canTypeToMonoWithI superVars subst to intern0
            in
            List.foldl
                (\argType ( acc, i0 ) ->
                    -- Pure classification path: stamps LTop (design §6.2).
                    let
                        ( mArg, i1 ) =
                            canTypeToMonoWithI superVars subst argType i0
                    in
                    Intern.hashCons (Mono.mFunction Mono.LTop [ mArg ] acc) i1
                )
                ( resultType, intern1 )
                argsAcc
