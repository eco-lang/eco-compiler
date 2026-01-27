module Compiler.Generate.Monomorphize exposing (monomorphize)

{-| This module transforms a TypedOptimized.GlobalGraph into a Monomorphized.MonoGraph
by specializing all polymorphic functions to their concrete type instantiations.

The monomorphization algorithm works as follows:

1.  Find the entry point (main function).
2.  Use a worklist to process each (Global, MonoType, Maybe LambdaId) specialization.
3.  For each work item, specialize the TOpt.Node into a MonoNode by:
    a. Unifying the polymorphic type with the concrete type to get a substitution.
    b. Applying the substitution to all types in the expression.
    c. Discovering new specializations needed and adding them to the worklist.
4.  Continue until the worklist is empty.


# Monomorphization

@docs monomorphize

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.Generate.MLIR.Types as Types
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Index as Index
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Generate.Monomorphize.Analysis as Analysis
import Compiler.Generate.Monomorphize.Specialize as Specialize
import Compiler.Generate.Monomorphize.State as State exposing (WorkItem(..))
import Compiler.Generate.Monomorphize.TypeSubst as TypeSubst
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet
import System.TypeCheck.IO as IO
import Utils.Crash



-- ========== STATE ==========


{-| State maintained during monomorphization, tracking work to be done and completed specializations.
-}
type alias MonoState =
    State.MonoState


{-| Check if a MonoType represents a function type.
-}
isFunctionType : Mono.MonoType -> Bool
isFunctionType monoType =
    case monoType of
        Mono.MFunction _ _ ->
            True

        _ ->
            False


{-| Verify that all function-typed MonoDefine nodes have MonoClosure expressions.
Returns an error message if the invariant is violated.

This enforces the invariant:

> Every MonoNode whose MonoType is a function (MFunction) must be callable, i.e.:
>
>   - either MonoTailFunc params body monoType, or
>   - MonoDefine expr monoType where expr is MonoClosure closureInfo body monoType.

-}
checkCallableTopLevels : MonoState -> Result String ()
checkCallableTopLevels state =
    let
        checkNode : ( Int, Mono.MonoNode ) -> Maybe String
        checkNode ( specId, node ) =
            case node of
                Mono.MonoDefine expr monoType ->
                    if isFunctionType monoType then
                        case expr of
                            Mono.MonoClosure _ _ _ ->
                                Nothing

                            _ ->
                                let
                                    globalName =
                                        case Mono.lookupSpecKey specId state.registry of
                                            Just ( Mono.Global (IO.Canonical ( author, pkg ) moduleName) name, _, _ ) ->
                                                author ++ "/" ++ pkg ++ ":" ++ moduleName ++ "." ++ name

                                            Just ( Mono.Accessor fieldName, _, _ ) ->
                                                "accessor_" ++ fieldName

                                            Nothing ->
                                                "unknown"
                                in
                                Just
                                    ("Monomorphization invariant violated: "
                                        ++ "function-typed MonoDefine is not a MonoClosure.\n"
                                        ++ "  Global: "
                                        ++ globalName
                                        ++ "\n"
                                        ++ "  SpecId: "
                                        ++ String.fromInt specId
                                        ++ "\n"
                                        ++ "  Type: <MonoType>"
                                        ++ "\n"
                                        ++ "  Expr: <MonoExpr>"
                                    )

                    else
                        Nothing

                _ ->
                    Nothing
    in
    case
        Dict.toList compare state.nodes
            |> List.filterMap checkNode
            |> List.head
    of
        Just msg ->
            Err msg

        Nothing ->
            Ok ()



-- ========== ENTRY POINT ==========


{-| Transform a typed optimized graph using a custom entry point name.

This is useful for testing when the entry point is not named "main".

-}
monomorphize : Name -> TypeEnv.GlobalTypeEnv -> TOpt.GlobalGraph -> Result String Mono.MonoGraph
monomorphize entryPointName globalTypeEnv (TOpt.GlobalGraph nodes _ _) =
    case findEntryPoint entryPointName nodes of
        Nothing ->
            Err ("No " ++ entryPointName ++ " function found")

        Just ( mainGlobal, mainType ) ->
            monomorphizeFromEntry mainGlobal mainType globalTypeEnv nodes


{-| Perform monomorphization from a given entry point.
-}
monomorphizeFromEntry : TOpt.Global -> Can.Type -> TypeEnv.GlobalTypeEnv -> Dict (List String) TOpt.Global TOpt.Node -> Result String Mono.MonoGraph
monomorphizeFromEntry mainGlobal mainType globalTypeEnv nodes =
    let
        mainMonoType : Mono.MonoType
        mainMonoType =
            canTypeToMonoType Dict.empty mainType

        currentModule : IO.Canonical
        currentModule =
            case mainGlobal of
                TOpt.Global canonical _ ->
                    canonical

        initialState : MonoState
        initialState =
            initState currentModule nodes globalTypeEnv

        stateWithMain : MonoState
        stateWithMain =
            { initialState
                | worklist =
                    [ SpecializeGlobal (toptGlobalToMono mainGlobal) mainMonoType Nothing ]
            }

        finalState : MonoState
        finalState =
            processWorklist stateWithMain
    in
    -- Check the callable-top-level invariant before returning
    case checkCallableTopLevels finalState of
        Err msg ->
            Err ("COMPILER BUG: " ++ msg)

        Ok () ->
            let
                mainKey : List String
                mainKey =
                    Mono.toComparableSpecKey (Mono.SpecKey (toptGlobalToMono mainGlobal) mainMonoType Nothing)

                mainSpecId : Maybe Mono.SpecId
                mainSpecId =
                    Dict.get identity mainKey finalState.registry.mapping

                mainInfo : Maybe Mono.MainInfo
                mainInfo =
                    Maybe.map Mono.StaticMain mainSpecId

                -- Compute complete ctor shapes for all custom types
                ctorShapes : Dict (List String) (List String) (List Mono.CtorShape)
                ctorShapes =
                    computeCtorShapesForGraph finalState.globalTypeEnv finalState.nodes
            in
            Ok
                (Mono.MonoGraph
                    { nodes = finalState.nodes
                    , registry = finalState.registry
                    , main = mainInfo
                    , ctorShapes = ctorShapes
                    }
                )



-- ========== INITIALIZATION ==========


{-| Initialize the monomorphization state with empty worklist and registry.
-}
initState : IO.Canonical -> Dict (List String) TOpt.Global TOpt.Node -> TypeEnv.GlobalTypeEnv -> MonoState
initState =
    State.initState


{-| Find an entry point by name in the global graph.
-}
findEntryPoint : Name -> Dict (List String) TOpt.Global TOpt.Node -> Maybe ( TOpt.Global, Can.Type )
findEntryPoint entryPointName nodes =
    Dict.foldl TOpt.compareGlobal
        (\global node acc ->
            case acc of
                Just _ ->
                    acc

                Nothing ->
                    case ( global, node ) of
                        ( TOpt.Global _ name, TOpt.Define _ _ tipe ) ->
                            if name == entryPointName then
                                Just ( global, tipe )

                            else
                                Nothing

                        ( TOpt.Global _ name, TOpt.TrackedDefine _ _ _ tipe ) ->
                            if name == entryPointName then
                                Just ( global, tipe )

                            else
                                Nothing

                        _ ->
                            Nothing
        )
        Nothing
        nodes



-- ========== WORKLIST PROCESSING ==========


{-| Process all pending specializations until the worklist is empty.
-}
processWorklist : MonoState -> MonoState
processWorklist state =
    case state.worklist of
        [] ->
            state

        (SpecializeGlobal global monoType maybeLambda) :: rest ->
            let
                ( specId, newRegistry ) =
                    Mono.getOrCreateSpecId global monoType maybeLambda state.registry

                state1 =
                    { state
                        | registry = newRegistry
                        , worklist = rest
                    }
            in
            if EverySet.member identity specId state1.inProgress then
                -- Skip to avoid infinite recursion when specializing recursive functions.
                processWorklist state1

            else if Dict.member identity specId state1.nodes then
                -- Already specialized, skip.
                processWorklist state1

            else
                let
                    -- Clear varTypes when starting a new function specialization
                    -- because we're entering a new scope with different local variables
                    state2 =
                        { state1
                            | inProgress = EverySet.insert identity specId state1.inProgress
                            , currentGlobal = Just global
                            , varTypes = Dict.empty
                        }
                in
                case global of
                    Mono.Accessor fieldName ->
                        -- Handle accessor specialization
                        let
                            ( monoNode, stateAfter ) =
                                specializeAccessorGlobal fieldName monoType state2

                            newState =
                                { stateAfter
                                    | nodes = Dict.insert identity specId monoNode stateAfter.nodes
                                    , inProgress = EverySet.remove identity specId stateAfter.inProgress
                                    , currentGlobal = Nothing
                                }
                        in
                        processWorklist newState

                    Mono.Global _ name ->
                        -- Existing logic with monoGlobalToTOpt and toptNodes lookup
                        let
                            toptGlobal =
                                monoGlobalToTOpt global
                        in
                        case Dict.get TOpt.toComparableGlobal toptGlobal state2.toptNodes of
                            Nothing ->
                                -- External or missing definition; treat as extern.
                                let
                                    newState =
                                        { state2
                                            | nodes = Dict.insert identity specId (Mono.MonoExtern monoType) state2.nodes
                                            , inProgress = EverySet.remove identity specId state2.inProgress
                                            , currentGlobal = Nothing
                                        }
                                in
                                processWorklist newState

                            Just toptNode ->
                                -- Specialize this node to concrete types.
                                -- Pass the global's name for constructor name population.
                                let
                                    ( monoNode, stateAfter ) =
                                        Specialize.specializeNode name toptNode monoType state2

                                    newState =
                                        { stateAfter
                                            | nodes = Dict.insert identity specId monoNode stateAfter.nodes
                                            , inProgress = EverySet.remove identity specId stateAfter.inProgress
                                            , currentGlobal = Nothing
                                        }
                                in
                                processWorklist newState


specializeAccessorGlobal : Name -> Mono.MonoType -> MonoState -> ( Mono.MonoNode, MonoState )
specializeAccessorGlobal fieldName monoType state =
    case monoType of
        Mono.MFunction [ Mono.MRecord fields ] fieldType ->
            let
                recordType =
                    Mono.MRecord fields

                ( fieldIndex, isUnboxed ) =
                    Specialize.lookupFieldIndex fieldName recordType

                paramName =
                    "record"

                bodyExpr =
                    Mono.MonoRecordAccess
                        (Mono.MonoVarLocal paramName recordType)
                        fieldName
                        fieldIndex
                        isUnboxed
                        fieldType
            in
            ( Mono.MonoTailFunc [ ( paramName, recordType ) ] bodyExpr monoType, state )

        _ ->
            Utils.Crash.crash "Monomorphize" "specializeAccessorGlobal" "Expected MFunction [MRecord ...] fieldType"


{-| Substitution mapping type variable names to their concrete monomorphic types.
-}
type alias Substitution =
    State.Substitution


{-| Apply a type substitution to a canonical type to produce a monomorphic type.
-}
applySubst : Substitution -> Can.Type -> Mono.MonoType
applySubst =
    TypeSubst.applySubst


canTypeToMonoType : Substitution -> Can.Type -> Mono.MonoType
canTypeToMonoType =
    TypeSubst.canTypeToMonoType



-- ========== LAYOUT HELPERS ==========
-- ========== KERNEL ABI TYPE DERIVATION ==========
-- ========== GLOBAL CONVERSIONS ==========


{-| Convert a typed optimized global reference to a monomorphized global reference.
-}
toptGlobalToMono : TOpt.Global -> Mono.Global
toptGlobalToMono (TOpt.Global canonical name) =
    Mono.Global canonical name


{-| Convert a monomorphized global reference to a typed optimized global reference.
-}
monoGlobalToTOpt : Mono.Global -> TOpt.Global
monoGlobalToTOpt global =
    case global of
        Mono.Global canonical name ->
            TOpt.Global canonical name

        Mono.Accessor _ ->
            Utils.Crash.crash "Monomorphize" "monoGlobalToTOpt" "Accessor should be handled before calling monoGlobalToTOpt"



-- ========== CTOR LAYOUT COMPUTATION ==========


{-| Build complete CtorShapes for all constructors in a union.
Uses the existing applySubst to convert Can.Type to MonoType.
-}
buildCompleteCtorShapes : List Name -> List Mono.MonoType -> List Can.Ctor -> List Mono.CtorShape
buildCompleteCtorShapes vars monoArgs alts =
    let
        -- Build substitution from type vars to mono args
        subst : Substitution
        subst =
            List.map2 Tuple.pair vars monoArgs
                |> Dict.fromList identity
    in
    List.map (buildCtorShapeFromUnion subst) alts


{-| Build a CtorShape from a Can.Ctor using the given substitution.
-}
buildCtorShapeFromUnion : Substitution -> Can.Ctor -> Mono.CtorShape
buildCtorShapeFromUnion subst (Can.Ctor ctorData) =
    let
        -- Use existing applySubst to monomorphize each argument type
        monoFieldTypes : List Mono.MonoType
        monoFieldTypes =
            List.map (applySubst subst) ctorData.args
    in
    { name = ctorData.name
    , tag = Index.toMachine ctorData.index
    , fieldTypes = monoFieldTypes
    }


{-| Compute complete ctor shapes for all custom types in the graph.
For each MCustom, looks up the union definition and builds shapes for ALL constructors,
even those not directly used in code.
-}
computeCtorShapesForGraph :
    TypeEnv.GlobalTypeEnv
    -> Dict Int Int Mono.MonoNode
    -> Dict (List String) (List String) (List Mono.CtorShape)
computeCtorShapesForGraph globalTypeEnv nodes =
    let
        customTypes =
            Analysis.collectAllCustomTypes nodes

        processCustomType monoType acc =
            case monoType of
                Mono.MCustom canonical typeName monoArgs ->
                    let
                        key =
                            Mono.toComparableMonoType monoType
                    in
                    case Analysis.lookupUnion globalTypeEnv canonical typeName of
                        Nothing ->
                            -- Canonical Union not found for custom constructor.
                            Utils.Crash.crash
                                ("Missing union for ctor shape: "
                                    ++ (ModuleName.toComparableCanonical canonical
                                            ++ [ typeName ]
                                            |> String.join " "
                                       )
                                )

                        Just (Can.Union unionData) ->
                            let
                                completeCtors =
                                    buildCompleteCtorShapes unionData.vars monoArgs unionData.alts
                            in
                            Dict.insert identity key completeCtors acc

                _ ->
                    acc

        compareTypes a b =
            compare (Mono.toComparableMonoType a) (Mono.toComparableMonoType b)
    in
    List.foldl processCustomType Dict.empty (EverySet.toList compareTypes customTypes)
