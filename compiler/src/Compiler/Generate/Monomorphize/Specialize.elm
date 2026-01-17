module Compiler.Generate.Monomorphize.Specialize exposing
    ( specializeNode
    , lookupFieldIndex
    )

{-| Expression and node specialization for monomorphization.

This module handles converting typed optimized expressions and nodes
into monomorphized form by applying type substitutions.


# Specialization

@docs specializeNode


# Definition Utilities


# Type Extraction

@docs lookupFieldIndex


# Type Building


# Global Conversion

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Generate.Monomorphize.Closure as Closure
import Compiler.Generate.Monomorphize.KernelAbi as KernelAbi
import Compiler.Generate.Monomorphize.State exposing (MonoState, Substitution, VarTypes, WorkItem(..))
import Compiler.Generate.Monomorphize.TypeSubst as TypeSubst
import Compiler.Optimize.Typed.DecisionTree as DT
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as IO
import Utils.Crash



-- ========== INTERNAL TYPES ==========


{-| A processed argument that might be pending accessor specialization.
Accessors need special handling because they must be specialized AFTER
call-site type unification to receive the fully-resolved record type.
-}
type ProcessedArg
    = ResolvedArg Mono.MonoExpr
    | PendingAccessor A.Region Name Can.Type



-- ========== NODE SPECIALIZATION ==========


{-| Specialize a typed optimized node to a monomorphized node at the requested concrete type.
The ctorName parameter is used to populate CtorLayout.name for constructor nodes.
-}
specializeNode : Name.Name -> TOpt.Node -> Mono.MonoType -> MonoState -> ( Mono.MonoNode, MonoState )
specializeNode ctorName node requestedMonoType state =
    case node of
        TOpt.Define expr _ canType ->
            let
                subst =
                    TypeSubst.unify canType requestedMonoType

                ( monoExpr0, state1 ) =
                    specializeExpr expr subst state

                ( monoExpr, state2 ) =
                    Closure.ensureCallableTopLevel monoExpr0 requestedMonoType state1
            in
            ( Mono.MonoDefine monoExpr requestedMonoType, state2 )

        TOpt.TrackedDefine _ expr _ canType ->
            let
                subst =
                    TypeSubst.unify canType requestedMonoType

                ( monoExpr0, state1 ) =
                    specializeExpr expr subst state

                ( monoExpr, state2 ) =
                    Closure.ensureCallableTopLevel monoExpr0 requestedMonoType state1
            in
            ( Mono.MonoDefine monoExpr requestedMonoType, state2 )

        TOpt.DefineTailFunc _ args body _ returnType ->
            let
                funcType =
                    buildFuncType args returnType

                subst =
                    TypeSubst.unify funcType requestedMonoType

                monoArgs =
                    List.map (specializeArg subst) args

                newVarTypes =
                    List.foldl
                        (\( name, monoParamType ) vt -> Dict.insert identity name monoParamType vt)
                        state.varTypes
                        monoArgs

                stateWithParams =
                    { state | varTypes = newVarTypes }

                augmentedSubst =
                    List.foldl
                        (\( ( _, canParamType ), ( _, monoParamType ) ) s ->
                            case canParamType of
                                Can.TVar varName ->
                                    Dict.insert identity varName monoParamType s

                                _ ->
                                    s
                        )
                        subst
                        (List.map2 Tuple.pair args monoArgs)

                ( monoBody, state1 ) =
                    specializeExpr body augmentedSubst stateWithParams

                monoReturnType =
                    TypeSubst.applySubst subst returnType
            in
            ( Mono.MonoTailFunc monoArgs monoBody monoReturnType, state1 )

        TOpt.Ctor index arity canType ->
            let
                subst =
                    TypeSubst.unify canType requestedMonoType

                ctorMonoType =
                    TypeSubst.applySubst subst canType

                tag =
                    Index.toMachine index

                layout =
                    buildCtorLayoutFromArity ctorName tag arity ctorMonoType

                ctorResultType =
                    extractCtorResultType arity requestedMonoType
            in
            ( Mono.MonoCtor layout ctorResultType, state )

        TOpt.Enum tag canType ->
            let
                monoType =
                    TypeSubst.applySubst (TypeSubst.unify canType requestedMonoType) canType
            in
            ( Mono.MonoEnum (Index.toMachine tag) monoType, state )

        TOpt.Box _ ->
            -- Box (for runtime representation) - treat as extern
            ( Mono.MonoExtern requestedMonoType, state )

        TOpt.Link linkedGlobal ->
            -- Link to another global - follow the link
            case Dict.get TOpt.toComparableGlobal linkedGlobal state.toptNodes of
                Nothing ->
                    ( Mono.MonoExtern requestedMonoType, state )

                Just linkedNode ->
                    let
                        linkedName =
                            case linkedGlobal of
                                TOpt.Global _ name ->
                                    name
                    in
                    specializeNode linkedName linkedNode requestedMonoType state

        TOpt.Kernel _ _ ->
            -- Inline kernel code - treat as extern
            ( Mono.MonoExtern requestedMonoType, state )

        TOpt.Manager _ ->
            -- Effect manager - treat as extern
            ( Mono.MonoExtern requestedMonoType, state )

        TOpt.Cycle names valueDefs funcDefs _ ->
            specializeCycle names valueDefs funcDefs requestedMonoType state

        TOpt.PortIncoming expr _ canType ->
            let
                subst =
                    TypeSubst.unify canType requestedMonoType

                ( monoExpr0, state1 ) =
                    specializeExpr expr subst state

                ( monoExpr, state2 ) =
                    Closure.ensureCallableTopLevel monoExpr0 requestedMonoType state1
            in
            ( Mono.MonoPortIncoming monoExpr requestedMonoType, state2 )

        TOpt.PortOutgoing expr _ canType ->
            let
                subst =
                    TypeSubst.unify canType requestedMonoType

                ( monoExpr0, state1 ) =
                    specializeExpr expr subst state

                ( monoExpr, state2 ) =
                    Closure.ensureCallableTopLevel monoExpr0 requestedMonoType state1
            in
            ( Mono.MonoPortOutgoing monoExpr requestedMonoType, state2 )


{-| Specialize a mutually recursive cycle, handling both value and function definitions.
-}
specializeCycle :
    List Name
    -> List ( Name, TOpt.Expr )
    -> List TOpt.Def
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoNode, MonoState )
specializeCycle _ valueDefs funcDefs requestedMonoType state =
    case ( List.isEmpty funcDefs, state.currentGlobal ) of
        ( True, _ ) ->
            specializeValueOnlyCycle valueDefs requestedMonoType state

        ( False, Nothing ) ->
            ( Mono.MonoExtern requestedMonoType, state )

        ( False, Just (Mono.Global requestedCanonical requestedName) ) ->
            specializeFunctionCycle
                requestedCanonical
                requestedName
                valueDefs
                funcDefs
                requestedMonoType
                state

        ( False, Just (Mono.Accessor _) ) ->
            -- Accessors are virtual globals and don't participate in cycles
            Utils.Crash.crash "Specialize" "specializeCycle" "Accessor should not appear in cycles"


{-| Specialize a cycle containing only value definitions.
-}
specializeValueOnlyCycle :
    List ( Name, TOpt.Expr )
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoNode, MonoState )
specializeValueOnlyCycle valueDefs requestedMonoType state =
    let
        subst =
            Dict.empty

        ( monoDefs, state1 ) =
            specializeValueDefs valueDefs subst state
    in
    ( Mono.MonoCycle monoDefs requestedMonoType, state1 )


{-| Specialize a cycle containing function definitions by creating separate nodes for each function.
-}
specializeFunctionCycle :
    IO.Canonical
    -> Name
    -> List ( Name, TOpt.Expr )
    -> List TOpt.Def
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoNode, MonoState )
specializeFunctionCycle requestedCanonical requestedName _ funcDefs requestedMonoType state =
    let
        maybeRequestedDef =
            List.filter (defHasName requestedName) funcDefs |> List.head

        sharedSubst : Substitution
        sharedSubst =
            case maybeRequestedDef of
                Just def ->
                    let
                        canType =
                            getDefCanonicalType def
                    in
                    TypeSubst.unify canType requestedMonoType

                Nothing ->
                    Dict.empty

        ( newNodes, stateAfter ) =
            List.foldl (specializeFunc requestedCanonical sharedSubst) ( state.nodes, state ) funcDefs

        requestedGlobal =
            Mono.Global requestedCanonical requestedName

        ( requestedSpecId, _ ) =
            Mono.getOrCreateSpecId requestedGlobal requestedMonoType Nothing stateAfter.registry
    in
    case Dict.get identity requestedSpecId newNodes of
        Just requestedNode ->
            ( requestedNode, { stateAfter | nodes = newNodes } )

        Nothing ->
            ( Mono.MonoExtern requestedMonoType, { stateAfter | nodes = newNodes } )


specializeFunc :
    IO.Canonical
    -> Substitution
    -> TOpt.Def
    -> ( Dict Int Int Mono.MonoNode, MonoState )
    -> ( Dict Int Int Mono.MonoNode, MonoState )
specializeFunc requestedCanonical sharedSubst def ( accNodes, accState ) =
    let
        name =
            getDefName def

        globalFun =
            Mono.Global requestedCanonical name

        canType =
            getDefCanonicalType def

        monoType =
            TypeSubst.applySubst sharedSubst canType

        ( specId, newRegistry ) =
            Mono.getOrCreateSpecId globalFun monoType Nothing accState.registry

        accState1 =
            { accState | registry = newRegistry }
    in
    if Dict.member identity specId accNodes then
        ( accNodes, accState1 )

    else
        let
            ( monoNode, accState2 ) =
                specializeFuncDefInCycle sharedSubst def accState1

            nextNodes =
                Dict.insert identity specId monoNode accNodes
        in
        ( nextNodes, accState2 )


specializeFuncDefInCycle :
    Substitution
    -> TOpt.Def
    -> MonoState
    -> ( Mono.MonoNode, MonoState )
specializeFuncDefInCycle subst def state =
    case def of
        TOpt.Def _ _ expr canType ->
            let
                monoType =
                    TypeSubst.applySubst subst canType

                ( monoExpr0, state1 ) =
                    specializeExpr expr subst state

                ( monoExpr, state2 ) =
                    Closure.ensureCallableTopLevel monoExpr0 monoType state1
            in
            ( Mono.MonoDefine monoExpr monoType, state2 )

        TOpt.TailDef _ _ args body returnType ->
            let
                monoArgs =
                    List.map (specializeArg subst) args

                newVarTypes =
                    List.foldl
                        (\( name, monoParamType ) vt -> Dict.insert identity name monoParamType vt)
                        state.varTypes
                        monoArgs

                stateWithParams =
                    { state | varTypes = newVarTypes }

                augmentedSubst =
                    List.foldl
                        (\( ( _, canParamType ), ( _, monoParamType ) ) s ->
                            case canParamType of
                                Can.TVar varName ->
                                    Dict.insert identity varName monoParamType s

                                _ ->
                                    s
                        )
                        subst
                        (List.map2 Tuple.pair args monoArgs)

                ( monoBody, state1 ) =
                    specializeExpr body augmentedSubst stateWithParams

                monoReturnType =
                    TypeSubst.applySubst subst returnType
            in
            ( Mono.MonoTailFunc monoArgs monoBody monoReturnType, state1 )



-- ========== VALUE DEFINITIONS ==========


{-| Specialize a list of value definitions in a cycle.
-}
specializeValueDefs :
    List ( Name, TOpt.Expr )
    -> Substitution
    -> MonoState
    -> ( List ( Name, Mono.MonoExpr ), MonoState )
specializeValueDefs values subst state =
    List.foldl
        (\( name, expr ) ( accDefs, accState ) ->
            let
                ( monoExpr, newState ) =
                    specializeExpr expr subst accState
            in
            ( accDefs ++ [ ( name, monoExpr ) ], newState )
        )
        ( [], state )
        values



-- ========== EXPRESSION SPECIALIZATION ==========


{-| Specialize a typed optimized expression to a monomorphized expression by applying type substitutions.
-}
specializeExpr : TOpt.Expr -> Substitution -> MonoState -> ( Mono.MonoExpr, MonoState )
specializeExpr expr subst state =
    case expr of
        TOpt.Bool _ value _ ->
            ( Mono.MonoLiteral (Mono.LBool value) Mono.MBool, state )

        TOpt.Chr _ value _ ->
            ( Mono.MonoLiteral (Mono.LChar value) Mono.MChar, state )

        TOpt.Str _ value _ ->
            ( Mono.MonoLiteral (Mono.LStr value) Mono.MString, state )

        TOpt.Int _ value canType ->
            let
                monoType =
                    TypeSubst.applySubst subst canType
            in
            case monoType of
                Mono.MFloat ->
                    ( Mono.MonoLiteral (Mono.LFloat (toFloat value)) monoType, state )

                _ ->
                    ( Mono.MonoLiteral (Mono.LInt value) monoType, state )

        TOpt.Float _ value canType ->
            let
                monoType =
                    TypeSubst.applySubst subst canType
            in
            ( Mono.MonoLiteral (Mono.LFloat value) monoType, state )

        TOpt.VarLocal name canType ->
            let
                monoType =
                    TypeSubst.applySubst subst canType
            in
            ( Mono.MonoVarLocal name monoType, state )

        TOpt.TrackedVarLocal _ name canType ->
            let
                monoType =
                    TypeSubst.applySubst subst canType
            in
            ( Mono.MonoVarLocal name monoType, state )

        TOpt.VarGlobal region global canType ->
            let
                monoType0 =
                    TypeSubst.applySubst subst canType

                monoType =
                    case monoType0 of
                        Mono.MVar _ _ ->
                            case Dict.get TOpt.toComparableGlobal global state.toptNodes of
                                Just (TOpt.Define _ _ defCanType) ->
                                    TypeSubst.applySubst subst defCanType

                                Just (TOpt.TrackedDefine _ _ _ defCanType) ->
                                    TypeSubst.applySubst subst defCanType

                                Just (TOpt.DefineTailFunc _ args _ _ returnType) ->
                                    TypeSubst.applySubst subst (buildFuncType args returnType)

                                Just (TOpt.Enum _ enumCanType) ->
                                    TypeSubst.applySubst subst enumCanType

                                Just (TOpt.Ctor _ _ ctorCanType) ->
                                    TypeSubst.applySubst subst ctorCanType

                                _ ->
                                    monoType0

                        _ ->
                            monoType0

                monoGlobal =
                    toptGlobalToMono global

                ( specId, newRegistry ) =
                    Mono.getOrCreateSpecId monoGlobal monoType Nothing state.registry

                newState =
                    { state
                        | registry = newRegistry
                        , worklist = SpecializeGlobal monoGlobal monoType Nothing :: state.worklist
                    }
            in
            ( Mono.MonoVarGlobal region specId monoType, newState )

        TOpt.VarEnum region global _ canType ->
            let
                monoType0 =
                    TypeSubst.applySubst subst canType

                monoType =
                    case monoType0 of
                        Mono.MVar _ _ ->
                            case Dict.get TOpt.toComparableGlobal global state.toptNodes of
                                Just (TOpt.Enum _ enumCanType) ->
                                    TypeSubst.applySubst subst enumCanType

                                _ ->
                                    monoType0

                        _ ->
                            monoType0

                monoGlobal =
                    toptGlobalToMono global

                ( specId, newRegistry ) =
                    Mono.getOrCreateSpecId monoGlobal monoType Nothing state.registry

                newState =
                    { state
                        | registry = newRegistry
                        , worklist = SpecializeGlobal monoGlobal monoType Nothing :: state.worklist
                    }
            in
            ( Mono.MonoVarGlobal region specId monoType, newState )

        TOpt.VarBox region global canType ->
            let
                monoType =
                    TypeSubst.applySubst subst canType

                monoGlobal =
                    toptGlobalToMono global

                ( specId, newRegistry ) =
                    Mono.getOrCreateSpecId monoGlobal monoType Nothing state.registry

                newState =
                    { state
                        | registry = newRegistry
                        , worklist = SpecializeGlobal monoGlobal monoType Nothing :: state.worklist
                    }
            in
            ( Mono.MonoVarGlobal region specId monoType, newState )

        TOpt.VarCycle region canonical name canType ->
            let
                monoType =
                    TypeSubst.applySubst subst canType

                monoGlobal =
                    Mono.Global canonical name

                ( specId, newRegistry ) =
                    Mono.getOrCreateSpecId monoGlobal monoType Nothing state.registry

                newState =
                    { state
                        | registry = newRegistry
                        , worklist = SpecializeGlobal monoGlobal monoType Nothing :: state.worklist
                    }
            in
            ( Mono.MonoVarGlobal region specId monoType, newState )

        TOpt.VarDebug region name _ _ canType ->
            let
                funcMonoType =
                    deriveKernelAbiType ( "Debug", name ) canType subst
            in
            ( Mono.MonoVarKernel region "Debug" name funcMonoType, state )

        TOpt.VarKernel region home name canType ->
            let
                funcMonoType =
                    deriveKernelAbiType ( home, name ) canType subst
            in
            ( Mono.MonoVarKernel region home name funcMonoType, state )

        TOpt.List region exprs canType ->
            let
                monoType =
                    TypeSubst.applySubst subst canType

                ( monoExprs, stateAfter ) =
                    specializeExprs exprs subst state
            in
            ( Mono.MonoList region monoExprs monoType, stateAfter )

        TOpt.Function params body canType ->
            let
                monoType =
                    TypeSubst.applySubst subst canType

                funcTypeParams =
                    TypeSubst.extractParamTypes monoType

                deriveParamType : Int -> ( Name, Can.Type ) -> ( Name, Mono.MonoType )
                deriveParamType idx ( name, paramCanType ) =
                    let
                        substType =
                            TypeSubst.applySubst subst paramCanType
                    in
                    case substType of
                        Mono.MVar _ _ ->
                            case List.drop idx funcTypeParams of
                                funcParamType :: _ ->
                                    ( name, funcParamType )

                                [] ->
                                    ( name, substType )

                        _ ->
                            ( name, substType )

                monoParams =
                    List.indexedMap deriveParamType params

                lambdaId =
                    Mono.AnonymousLambda state.currentModule state.lambdaCounter

                newVarTypes =
                    List.foldl
                        (\( name, monoParamType ) vt ->
                            Dict.insert identity name monoParamType vt
                        )
                        state.varTypes
                        monoParams

                stateWithLambda =
                    { state
                        | lambdaCounter = state.lambdaCounter + 1
                        , varTypes = newVarTypes
                    }

                augmentedSubst =
                    List.foldl
                        (\( ( _, paramCanType ), ( _, monoParamType ) ) s ->
                            case paramCanType of
                                Can.TVar varName ->
                                    Dict.insert identity varName monoParamType s

                                _ ->
                                    s
                        )
                        subst
                        (List.map2 Tuple.pair params monoParams)

                ( monoBody, stateAfter ) =
                    specializeExpr body augmentedSubst stateWithLambda

                captures =
                    Closure.computeClosureCaptures monoParams monoBody

                closureInfo =
                    { lambdaId = lambdaId
                    , captures = captures
                    , params = monoParams
                    }
            in
            ( Mono.MonoClosure closureInfo monoBody monoType, stateAfter )

        TOpt.TrackedFunction params body canType ->
            let
                monoType =
                    TypeSubst.applySubst subst canType

                funcTypeParams =
                    TypeSubst.extractParamTypes monoType

                deriveParamType : Int -> ( A.Located Name, Can.Type ) -> ( Name, Mono.MonoType )
                deriveParamType idx ( locName, paramCanType ) =
                    let
                        name =
                            A.toValue locName

                        substType =
                            TypeSubst.applySubst subst paramCanType
                    in
                    case substType of
                        Mono.MVar _ _ ->
                            case List.drop idx funcTypeParams of
                                funcParamType :: _ ->
                                    ( name, funcParamType )

                                [] ->
                                    ( name, substType )

                        _ ->
                            ( name, substType )

                monoParams =
                    List.indexedMap deriveParamType params

                lambdaId =
                    Mono.AnonymousLambda state.currentModule state.lambdaCounter

                newVarTypes =
                    List.foldl
                        (\( name, monoParamType ) vt ->
                            Dict.insert identity name monoParamType vt
                        )
                        state.varTypes
                        monoParams

                stateWithLambda =
                    { state
                        | lambdaCounter = state.lambdaCounter + 1
                        , varTypes = newVarTypes
                    }

                augmentedSubst =
                    List.foldl
                        (\( ( _, paramCanType ), ( _, monoParamType ) ) s ->
                            case paramCanType of
                                Can.TVar varName ->
                                    Dict.insert identity varName monoParamType s

                                _ ->
                                    s
                        )
                        subst
                        (List.map2 Tuple.pair params monoParams)

                ( monoBody, stateAfter ) =
                    specializeExpr body augmentedSubst stateWithLambda

                captures =
                    Closure.computeClosureCaptures monoParams monoBody

                closureInfo =
                    { lambdaId = lambdaId
                    , captures = captures
                    , params = monoParams
                    }
            in
            ( Mono.MonoClosure closureInfo monoBody monoType, stateAfter )

        TOpt.Call region func args canType ->
            -- Two-phase argument processing: defer accessor specialization until after
            -- call-site type unification, so accessors receive fully-resolved record types.
            let
                ( processedArgs, argTypes, state1 ) =
                    processCallArgs args subst state
            in
            case func of
                TOpt.VarGlobal funcRegion global funcCanType ->
                    let
                        callSubst =
                            TypeSubst.unifyFuncCall funcCanType argTypes canType subst

                        funcMonoType =
                            TypeSubst.applySubst callSubst funcCanType

                        paramTypes =
                            TypeSubst.extractParamTypes funcMonoType

                        ( monoArgs, state2 ) =
                            resolveProcessedArgs processedArgs paramTypes callSubst state1

                        resultMonoType =
                            TypeSubst.applySubst callSubst canType

                        monoGlobal =
                            toptGlobalToMono global

                        ( specId, newRegistry ) =
                            Mono.getOrCreateSpecId monoGlobal funcMonoType Nothing state2.registry

                        newState =
                            { state2
                                | registry = newRegistry
                                , worklist = SpecializeGlobal monoGlobal funcMonoType Nothing :: state2.worklist
                            }

                        monoFunc =
                            Mono.MonoVarGlobal funcRegion specId funcMonoType
                    in
                    ( Mono.MonoCall region monoFunc monoArgs resultMonoType, newState )

                TOpt.VarKernel funcRegion home name funcCanType ->
                    let
                        callSubst =
                            TypeSubst.unifyFuncCall funcCanType argTypes canType subst

                        funcMonoType =
                            deriveKernelAbiType ( home, name ) funcCanType callSubst

                        paramTypes =
                            TypeSubst.extractParamTypes funcMonoType

                        ( monoArgs, state2 ) =
                            resolveProcessedArgs processedArgs paramTypes callSubst state1

                        resultMonoType =
                            TypeSubst.applySubst callSubst canType

                        monoFunc =
                            Mono.MonoVarKernel funcRegion home name funcMonoType
                    in
                    ( Mono.MonoCall region monoFunc monoArgs resultMonoType, state2 )

                TOpt.VarDebug funcRegion name _ _ funcCanType ->
                    let
                        callSubst =
                            TypeSubst.unifyFuncCall funcCanType argTypes canType subst

                        funcMonoType =
                            deriveKernelAbiType ( "Debug", name ) funcCanType callSubst

                        paramTypes =
                            TypeSubst.extractParamTypes funcMonoType

                        ( monoArgs, state2 ) =
                            resolveProcessedArgs processedArgs paramTypes callSubst state1

                        resultMonoType =
                            TypeSubst.applySubst callSubst canType

                        monoFunc =
                            Mono.MonoVarKernel funcRegion "Debug" name funcMonoType
                    in
                    ( Mono.MonoCall region monoFunc monoArgs resultMonoType, state2 )

                _ ->
                    -- Fallback: locally-bound or non-global function.
                    -- We still want accessor args to see fully-resolved record types,
                    -- so we run unifyFuncCall on the *canonical* type of `func`.
                    let
                        funcCanType =
                            TOpt.typeOf func

                        -- Unify the local function's canonical type with the actual arg types
                        -- and the expected result type at this call site.
                        callSubst =
                            TypeSubst.unifyFuncCall funcCanType argTypes canType subst

                        -- Monomorphized function type for this *call*, with call-site constraints.
                        funcMonoType =
                            TypeSubst.applySubst callSubst funcCanType

                        -- Parameter types derived from the unified function type.
                        paramTypes =
                            TypeSubst.extractParamTypes funcMonoType

                        -- Resolve pending accessors using the unified substitution and param types.
                        ( monoArgs, state2 ) =
                            resolveProcessedArgs processedArgs paramTypes callSubst state1

                        -- Now specialize the callee expression itself under the unified substitution.
                        ( monoFunc, state3 ) =
                            specializeExpr func callSubst state2

                        -- Call result type, also under the unified substitution.
                        resultMonoType =
                            TypeSubst.applySubst callSubst canType
                    in
                    ( Mono.MonoCall region monoFunc monoArgs resultMonoType, state3 )

        TOpt.TailCall name args canType ->
            let
                monoType =
                    TypeSubst.applySubst subst canType

                ( monoArgs, stateAfter ) =
                    specializeNamedExprs args subst state
            in
            ( Mono.MonoTailCall name monoArgs monoType, stateAfter )

        TOpt.If branches final canType ->
            let
                monoType =
                    TypeSubst.applySubst subst canType

                ( monoBranches, state1 ) =
                    specializeBranches branches subst state

                ( monoFinal, state2 ) =
                    specializeExpr final subst state1
            in
            ( Mono.MonoIf monoBranches monoFinal monoType, state2 )

        TOpt.Let def body canType ->
            let
                monoType =
                    TypeSubst.applySubst subst canType

                ( monoDef, state1 ) =
                    specializeDef def subst state

                defName =
                    getDefName def

                defCanType =
                    getDefCanonicalType def

                defMonoType =
                    TypeSubst.applySubst subst defCanType

                stateWithVar =
                    { state1 | varTypes = Dict.insert identity defName defMonoType state1.varTypes }

                ( monoBody, state2 ) =
                    specializeExpr body subst stateWithVar
            in
            ( Mono.MonoLet monoDef monoBody monoType, state2 )

        TOpt.Destruct destructor body canType ->
            let
                monoType =
                    TypeSubst.applySubst subst canType

                monoDestructor =
                    specializeDestructor destructor subst state.varTypes

                (Mono.MonoDestructor destructorName _ destructorType) =
                    monoDestructor

                stateWithVar =
                    { state | varTypes = Dict.insert identity destructorName destructorType state.varTypes }

                ( monoBody, stateAfter ) =
                    specializeExpr body subst stateWithVar
            in
            ( Mono.MonoDestruct monoDestructor monoBody monoType, stateAfter )

        TOpt.Case label root decider jumps canType ->
            let
                monoType =
                    TypeSubst.applySubst subst canType

                initialVarTypes =
                    state.varTypes

                ( monoDecider, state1 ) =
                    specializeDecider decider subst state

                state1WithResetVarTypes =
                    { state1 | varTypes = initialVarTypes }

                ( monoJumps, state2 ) =
                    specializeJumps jumps subst state1WithResetVarTypes
            in
            ( Mono.MonoCase label root monoDecider monoJumps monoType, state2 )

        TOpt.Accessor region fieldName canType ->
            -- NOTE: This handles standalone accessor expressions (not passed as arguments).
            -- The MonoType derived here may have an incomplete record layout if the
            -- accessor's row variable is not yet bound in the substitution.
            --
            -- INVARIANT: Any accessor that is actually *invoked* at runtime must be
            -- specialized via the virtual-global mechanism (Mono.Accessor + worklist),
            -- which happens in resolveProcessedArg when the accessor is passed as an
            -- argument to a function call. The virtual-global path derives the accessor's
            -- MonoType from the fully-resolved parameter type, ensuring correct field indices.
            --
            -- A standalone accessor with incomplete type is only acceptable if it never
            -- participates in layout-dependent operations (e.g., dead code or debug output).
            let
                monoType =
                    TypeSubst.applySubst subst canType

                accessorGlobal =
                    Mono.Accessor fieldName

                ( specId, newRegistry ) =
                    Mono.getOrCreateSpecId accessorGlobal monoType Nothing state.registry

                newState =
                    { state
                        | registry = newRegistry
                        , worklist = SpecializeGlobal accessorGlobal monoType Nothing :: state.worklist
                    }
            in
            ( Mono.MonoVarGlobal region specId monoType, newState )

        TOpt.Access record _ fieldName canType ->
            let
                monoType =
                    TypeSubst.applySubst subst canType

                ( monoRecord, stateAfter ) =
                    specializeExpr record subst state

                recordType =
                    Mono.typeOf monoRecord

                ( fieldIndex, isUnboxed ) =
                    lookupFieldIndex fieldName recordType
            in
            ( Mono.MonoRecordAccess monoRecord fieldName fieldIndex isUnboxed monoType, stateAfter )

        TOpt.Update _ record updates canType ->
            let
                monoType =
                    TypeSubst.applySubst subst canType

                ( monoRecord, state1 ) =
                    specializeExpr record subst state

                recordType =
                    Mono.typeOf monoRecord

                layout =
                    getRecordLayout recordType

                ( monoUpdates, state2 ) =
                    specializeUpdates updates layout subst state1
            in
            ( Mono.MonoRecordUpdate monoRecord monoUpdates layout monoType, state2 )

        TOpt.Record fields canType ->
            let
                monoType =
                    TypeSubst.applySubst subst canType

                layout =
                    getRecordLayout monoType

                ( monoFields, stateAfter ) =
                    specializeRecordFields fields layout subst state
            in
            ( Mono.MonoRecordCreate monoFields layout monoType, stateAfter )

        TOpt.TrackedRecord _ fields canType ->
            let
                monoType =
                    TypeSubst.applySubst subst canType

                layout =
                    getRecordLayout monoType

                ( monoFields, stateAfter ) =
                    specializeTrackedRecordFields fields layout subst state
            in
            ( Mono.MonoRecordCreate monoFields layout monoType, stateAfter )

        TOpt.Unit _ ->
            ( Mono.MonoUnit, state )

        TOpt.Tuple region a b rest canType ->
            let
                monoType =
                    TypeSubst.applySubst subst canType

                layout =
                    getTupleLayout monoType

                ( monoA, state1 ) =
                    specializeExpr a subst state

                ( monoB, state2 ) =
                    specializeExpr b subst state1

                ( monoRest, state3 ) =
                    specializeExprs rest subst state2

                allExprs =
                    monoA :: monoB :: monoRest
            in
            ( Mono.MonoTupleCreate region allExprs layout monoType, state3 )

        TOpt.Shader _ _ _ _ ->
            ( Mono.MonoUnit, state )



-- ========== EXPRESSION LIST HELPERS ==========


{-| Specialize a list of expressions.
-}
specializeExprs : List TOpt.Expr -> Substitution -> MonoState -> ( List Mono.MonoExpr, MonoState )
specializeExprs exprs subst state =
    List.foldr
        (\e ( acc, st ) ->
            let
                ( me, st1 ) =
                    specializeExpr e subst st
            in
            ( me :: acc, st1 )
        )
        ( [], state )
        exprs


{-| Process call arguments, deferring accessor specialization.

Returns:

  - processed args (some are PendingAccessor),
  - the monomorphic arg types for call-site unification,
  - updated MonoState.

-}
processCallArgs :
    List TOpt.Expr
    -> Substitution
    -> MonoState
    -> ( List ProcessedArg, List Mono.MonoType, MonoState )
processCallArgs args subst state =
    List.foldr
        (\arg ( accArgs, accTypes, st ) ->
            case arg of
                TOpt.Accessor region fieldName canType ->
                    let
                        -- Type for unification only; may have incomplete row.
                        -- We will NOT use this to derive the accessor's final MonoType.
                        monoType =
                            TypeSubst.applySubst subst canType
                    in
                    ( PendingAccessor region fieldName canType :: accArgs
                    , monoType :: accTypes
                    , st
                    )

                _ ->
                    let
                        ( monoExpr, st1 ) =
                            specializeExpr arg subst st
                    in
                    ( ResolvedArg monoExpr :: accArgs
                    , Mono.typeOf monoExpr :: accTypes
                    , st1
                    )
        )
        ( [], [], state )
        args


{-| Resolve a single processed argument.

For PendingAccessor, derives the accessor's MonoType from the expected
parameter type (which must be a record), NOT from the accessor's canonical type.

-}
resolveProcessedArg :
    ProcessedArg
    -> Maybe Mono.MonoType
    -> Substitution
    -> MonoState
    -> ( Mono.MonoExpr, MonoState )
resolveProcessedArg processedArg maybeParamType subst state =
    case processedArg of
        ResolvedArg monoExpr ->
            ( monoExpr, state )

        PendingAccessor region fieldName _ ->
            case maybeParamType of
                Just (Mono.MFunction [ Mono.MRecord layout ] _) ->
                    -- The parameter type is a function from record to something.
                    -- Derive accessor's MonoType from the full record layout.
                    let
                        maybeFieldInfo =
                            List.filter (\f -> f.name == fieldName) layout.fields
                                |> List.head

                        fieldType =
                            case maybeFieldInfo of
                                Just fi ->
                                    fi.monoType

                                Nothing ->
                                    Utils.Crash.crash
                                        "Specialize"
                                        "resolveProcessedArg"
                                        ("Field " ++ fieldName ++ " not found in record layout. This is a compiler bug.")

                        recordType =
                            Mono.MRecord layout

                        accessorMonoType =
                            Mono.MFunction [ recordType ] fieldType

                        accessorGlobal =
                            Mono.Accessor fieldName

                        ( specId, newRegistry ) =
                            Mono.getOrCreateSpecId accessorGlobal accessorMonoType Nothing state.registry

                        newState =
                            { state
                                | registry = newRegistry
                                , worklist = SpecializeGlobal accessorGlobal accessorMonoType Nothing :: state.worklist
                            }
                    in
                    ( Mono.MonoVarGlobal region specId accessorMonoType, newState )

                Just (Mono.MRecord layout) ->
                    -- The parameter type is directly a record (accessor applied to record).
                    -- This case handles when the accessor IS the function being called.
                    let
                        maybeFieldInfo =
                            List.filter (\f -> f.name == fieldName) layout.fields
                                |> List.head

                        fieldType =
                            case maybeFieldInfo of
                                Just fi ->
                                    fi.monoType

                                Nothing ->
                                    Utils.Crash.crash
                                        "Specialize"
                                        "resolveProcessedArg"
                                        ("Field " ++ fieldName ++ " not found in record layout (direct). This is a compiler bug.")

                        recordType =
                            Mono.MRecord layout

                        accessorMonoType =
                            Mono.MFunction [ recordType ] fieldType

                        accessorGlobal =
                            Mono.Accessor fieldName

                        ( specId, newRegistry ) =
                            Mono.getOrCreateSpecId accessorGlobal accessorMonoType Nothing state.registry

                        newState =
                            { state
                                | registry = newRegistry
                                , worklist = SpecializeGlobal accessorGlobal accessorMonoType Nothing :: state.worklist
                            }
                    in
                    ( Mono.MonoVarGlobal region specId accessorMonoType, newState )

                _ ->
                    Utils.Crash.crash
                        "Specialize"
                        "resolveProcessedArg"
                        "Accessor argument did not receive a record parameter type after monomorphization. This is a compiler bug."


{-| Resolve a list of processed arguments using the callee's parameter types.
-}
resolveProcessedArgs :
    List ProcessedArg
    -> List Mono.MonoType
    -> Substitution
    -> MonoState
    -> ( List Mono.MonoExpr, MonoState )
resolveProcessedArgs processedArgs paramTypes subst state =
    let
        step processedArg ( acc, st, remainingParams ) =
            let
                ( maybeParam, rest ) =
                    case remainingParams of
                        p :: ps ->
                            ( Just p, ps )

                        [] ->
                            ( Nothing, [] )

                ( monoExpr, st1 ) =
                    resolveProcessedArg processedArg maybeParam subst st
            in
            ( monoExpr :: acc, st1, rest )

        ( revArgs, finalState, _ ) =
            List.foldl step ( [], state, paramTypes ) processedArgs
    in
    ( List.reverse revArgs, finalState )


{-| Specialize a list of named expressions.
-}
specializeNamedExprs :
    List ( Name, TOpt.Expr )
    -> Substitution
    -> MonoState
    -> ( List ( Name, Mono.MonoExpr ), MonoState )
specializeNamedExprs namedExprs subst state =
    List.foldr
        (\( name, e ) ( acc, st ) ->
            let
                ( me, st1 ) =
                    specializeExpr e subst st
            in
            ( ( name, me ) :: acc, st1 )
        )
        ( [], state )
        namedExprs


{-| Specialize if-expression branches (condition-body pairs).
-}
specializeBranches :
    List ( TOpt.Expr, TOpt.Expr )
    -> Substitution
    -> MonoState
    -> ( List ( Mono.MonoExpr, Mono.MonoExpr ), MonoState )
specializeBranches branches subst state =
    let
        initialVarTypes =
            state.varTypes
    in
    List.foldr
        (\( cond, body ) ( acc, st ) ->
            let
                ( mCond, st1 ) =
                    specializeExpr cond subst st

                st1WithResetVarTypes =
                    { st1 | varTypes = initialVarTypes }

                ( mBody, st2 ) =
                    specializeExpr body subst st1WithResetVarTypes
            in
            ( ( mCond, mBody ) :: acc, st2 )
        )
        ( [], state )
        branches



-- ========== CONSTRUCTOR HELPERS ==========


{-| Extract the result type of a constructor after peeling off function arguments.
-}
extractCtorResultType : Int -> Mono.MonoType -> Mono.MonoType
extractCtorResultType n monoType =
    if n <= 0 then
        monoType

    else
        case monoType of
            Mono.MFunction args result ->
                extractCtorResultType (n - List.length args) result

            _ ->
                monoType



-- ========== CYCLE SPECIALIZATION HELPERS ==========


{-| Check if a definition has the given name.
-}
defHasName : Name -> TOpt.Def -> Bool
defHasName targetName def =
    case def of
        TOpt.Def _ name _ _ ->
            name == targetName

        TOpt.TailDef _ name _ _ _ ->
            name == targetName


{-| Get the name from a definition.
-}
getDefName : TOpt.Def -> Name
getDefName def =
    case def of
        TOpt.Def _ name _ _ ->
            name

        TOpt.TailDef _ name _ _ _ ->
            name


{-| Get the canonical type from a definition.
-}
getDefCanonicalType : TOpt.Def -> Can.Type
getDefCanonicalType def =
    case def of
        TOpt.Def _ _ _ canType ->
            canType

        TOpt.TailDef _ _ args _ returnType ->
            buildFuncType args returnType



-- ========== DEFINITION SPECIALIZATION HELPERS ==========


{-| Specialize a local definition.
-}
specializeDef : TOpt.Def -> Substitution -> MonoState -> ( Mono.MonoDef, MonoState )
specializeDef def subst state =
    case def of
        TOpt.Def _ name expr _ ->
            let
                ( monoExpr, stateAfter ) =
                    specializeExpr expr subst state
            in
            ( Mono.MonoDef name monoExpr, stateAfter )

        TOpt.TailDef _ name args expr _ ->
            let
                monoArgs =
                    List.map (specializeArg subst) args

                newVarTypes =
                    List.foldl
                        (\( pname, monoParamType ) vt ->
                            Dict.insert identity pname monoParamType vt
                        )
                        state.varTypes
                        monoArgs

                stateWithParams =
                    { state | varTypes = newVarTypes }

                augmentedSubst =
                    List.foldl
                        (\( ( _, canParamType ), ( _, monoParamType ) ) s ->
                            case canParamType of
                                Can.TVar varName ->
                                    Dict.insert identity varName monoParamType s

                                _ ->
                                    s
                        )
                        subst
                        (List.map2 Tuple.pair args monoArgs)

                ( monoExpr, stateAfter ) =
                    specializeExpr expr augmentedSubst stateWithParams
            in
            ( Mono.MonoTailDef name monoArgs monoExpr, stateAfter )


specializeDestructor : TOpt.Destructor -> Substitution -> VarTypes -> Mono.MonoDestructor
specializeDestructor (TOpt.Destructor name path canType) subst _ =
    let
        monoPath =
            specializePath path

        monoType =
            TypeSubst.applySubst subst canType
    in
    Mono.MonoDestructor name monoPath monoType


specializePath : TOpt.Path -> Mono.MonoPath
specializePath path =
    case path of
        TOpt.Index index hint subPath ->
            Mono.MonoIndex (Index.toMachine index) (hintToKind hint) (specializePath subPath)

        TOpt.ArrayIndex idx subPath ->
            Mono.MonoIndex idx Mono.CustomContainer (specializePath subPath)

        TOpt.Field _ subPath ->
            Mono.MonoField 0 (specializePath subPath)

        TOpt.Unbox subPath ->
            Mono.MonoUnbox (specializePath subPath)

        TOpt.Root name ->
            Mono.MonoRoot name


{-| Convert ContainerHint to ContainerKind for monomorphized paths.
-}
hintToKind : TOpt.ContainerHint -> Mono.ContainerKind
hintToKind hint =
    case hint of
        TOpt.HintList ->
            Mono.ListContainer

        TOpt.HintTuple2 ->
            Mono.Tuple2Container

        TOpt.HintTuple3 ->
            Mono.Tuple3Container

        TOpt.HintCustom ->
            Mono.CustomContainer

        TOpt.HintUnknown ->
            Mono.CustomContainer


{-| Specialize a pattern match decider tree.
-}
specializeDecider : TOpt.Decider TOpt.Choice -> Substitution -> MonoState -> ( Mono.Decider Mono.MonoChoice, MonoState )
specializeDecider decider subst state =
    case decider of
        TOpt.Leaf choice ->
            let
                ( monoChoice, stateAfter ) =
                    specializeChoice choice subst state
            in
            ( Mono.Leaf monoChoice, stateAfter )

        TOpt.Chain testChain success failure ->
            let
                initialVarTypes =
                    state.varTypes

                ( monoSuccess, state1 ) =
                    specializeDecider success subst state

                state1WithResetVarTypes =
                    { state1 | varTypes = initialVarTypes }

                ( monoFailure, state2 ) =
                    specializeDecider failure subst state1WithResetVarTypes
            in
            ( Mono.Chain testChain monoSuccess monoFailure, state2 )

        TOpt.FanOut path edges fallback ->
            let
                initialVarTypes =
                    state.varTypes

                ( monoEdges, state1 ) =
                    specializeEdges edges subst state

                state1WithResetVarTypes =
                    { state1 | varTypes = initialVarTypes }

                ( monoFallback, state2 ) =
                    specializeDecider fallback subst state1WithResetVarTypes
            in
            ( Mono.FanOut path monoEdges monoFallback, state2 )


specializeChoice : TOpt.Choice -> Substitution -> MonoState -> ( Mono.MonoChoice, MonoState )
specializeChoice choice subst state =
    case choice of
        TOpt.Inline expr ->
            let
                ( monoExpr, stateAfter ) =
                    specializeExpr expr subst state
            in
            ( Mono.Inline monoExpr, stateAfter )

        TOpt.Jump index ->
            ( Mono.Jump index, state )


specializeEdges : List ( DT.Test, TOpt.Decider TOpt.Choice ) -> Substitution -> MonoState -> ( List ( DT.Test, Mono.Decider Mono.MonoChoice ), MonoState )
specializeEdges edges subst state =
    let
        initialVarTypes =
            state.varTypes
    in
    List.foldr
        (\( test, decider ) ( acc, st ) ->
            let
                stWithResetVarTypes =
                    { st | varTypes = initialVarTypes }

                ( monoDecider, newSt ) =
                    specializeDecider decider subst stWithResetVarTypes
            in
            ( ( test, monoDecider ) :: acc, newSt )
        )
        ( [], state )
        edges


specializeJumps : List ( Int, TOpt.Expr ) -> Substitution -> MonoState -> ( List ( Int, Mono.MonoExpr ), MonoState )
specializeJumps jumps subst state =
    let
        initialVarTypes =
            state.varTypes
    in
    List.foldr
        (\( idx, expr ) ( acc, st ) ->
            let
                stWithResetVarTypes =
                    { st | varTypes = initialVarTypes }

                ( monoExpr, newSt ) =
                    specializeExpr expr subst stWithResetVarTypes
            in
            ( ( idx, monoExpr ) :: acc, newSt )
        )
        ( [], state )
        jumps


specializeRecordFields : Dict String Name TOpt.Expr -> Mono.RecordLayout -> Substitution -> MonoState -> ( List Mono.MonoExpr, MonoState )
specializeRecordFields fields layout subst state =
    let
        fieldsByName =
            fields
    in
    List.foldr
        (\fieldInfo ( acc, st ) ->
            case Dict.get identity fieldInfo.name fieldsByName of
                Just expr ->
                    let
                        ( monoExpr, newSt ) =
                            specializeExpr expr subst st
                    in
                    ( monoExpr :: acc, newSt )

                Nothing ->
                    ( Mono.MonoUnit :: acc, st )
        )
        ( [], state )
        layout.fields


specializeTrackedRecordFields : Dict String (A.Located Name) TOpt.Expr -> Mono.RecordLayout -> Substitution -> MonoState -> ( List Mono.MonoExpr, MonoState )
specializeTrackedRecordFields fields layout subst state =
    let
        fieldsByName =
            Dict.foldl A.compareLocated
                (\locName expr acc -> Dict.insert identity (A.toValue locName) expr acc)
                Dict.empty
                fields
    in
    List.foldr
        (\fieldInfo ( acc, st ) ->
            case Dict.get identity fieldInfo.name fieldsByName of
                Just expr ->
                    let
                        ( monoExpr, newSt ) =
                            specializeExpr expr subst st
                    in
                    ( monoExpr :: acc, newSt )

                Nothing ->
                    ( Mono.MonoUnit :: acc, st )
        )
        ( [], state )
        layout.fields


specializeUpdates : Dict String (A.Located Name) TOpt.Expr -> Mono.RecordLayout -> Substitution -> MonoState -> ( List ( Int, Mono.MonoExpr ), MonoState )
specializeUpdates updates layout subst state =
    Dict.foldl A.compareLocated
        (\locName expr ( acc, st ) ->
            let
                fieldName =
                    A.toValue locName

                ( monoExpr, newSt ) =
                    specializeExpr expr subst st

                fieldIndex =
                    List.foldl
                        (\f idx ->
                            if f.name == fieldName then
                                f.index

                            else
                                idx
                        )
                        0
                        layout.fields
            in
            ( ( fieldIndex, monoExpr ) :: acc, newSt )
        )
        ( [], state )
        updates


{-| Specialize a function argument by applying type substitution.
-}
specializeArg : Substitution -> ( A.Located Name, Can.Type ) -> ( Name, Mono.MonoType )
specializeArg subst ( locName, canType ) =
    ( A.toValue locName, TypeSubst.applySubst subst canType )



-- ========== LAYOUT HELPERS ==========


{-| Extract record layout from a monomorphic type.
-}
getRecordLayout : Mono.MonoType -> Mono.RecordLayout
getRecordLayout monoType =
    case monoType of
        Mono.MRecord layout ->
            layout

        _ ->
            { fieldCount = 0
            , unboxedCount = 0
            , unboxedBitmap = 0
            , fields = []
            }


{-| Extract the tuple layout from a tuple MonoType.
-}
getTupleLayout : Mono.MonoType -> Mono.TupleLayout
getTupleLayout monoType =
    case monoType of
        Mono.MTuple layout ->
            layout

        _ ->
            { arity = 0
            , unboxedBitmap = 0
            , elements = []
            }


{-| Look up the index and unboxed status of a record field by name.
-}
lookupFieldIndex : Name -> Mono.MonoType -> ( Int, Bool )
lookupFieldIndex fieldName monoType =
    case monoType of
        Mono.MRecord layout ->
            List.foldl
                (\f acc ->
                    if f.name == fieldName then
                        ( f.index, f.isUnboxed )

                    else
                        acc
                )
                ( 0, False )
                layout.fields

        _ ->
            ( 0, False )


{-| Build a function type from a list of arguments and a return type.
-}
buildFuncType : List ( A.Located Name, Can.Type ) -> Can.Type -> Can.Type
buildFuncType args returnType =
    List.foldr
        (\( _, argType ) acc ->
            Can.TLambda argType acc
        )
        returnType
        args


{-| Build a constructor layout from name, tag, arity, and monomorphic type information.
-}
buildCtorLayoutFromArity : Name.Name -> Int -> Int -> Mono.MonoType -> Mono.CtorLayout
buildCtorLayoutFromArity ctorName tag arity ctorMonoType =
    let
        fieldTypes =
            extractFieldTypes arity ctorMonoType

        fields =
            List.indexedMap
                (\idx ty ->
                    { name = "field" ++ String.fromInt idx
                    , index = idx
                    , monoType = ty
                    , isUnboxed = Mono.canUnbox ty
                    }
                )
                fieldTypes

        unboxedBitmap =
            List.foldl
                (\field acc ->
                    if field.isUnboxed && field.index < 32 then
                        acc + (2 ^ field.index)

                    else
                        acc
                )
                0
                fields

        unboxedCount =
            List.length (List.filter .isUnboxed fields)
    in
    { name = ctorName
    , tag = tag
    , unboxedBitmap = unboxedBitmap
    , unboxedCount = unboxedCount
    , fields = fields
    }


{-| Extract a specific number of argument types from a function type.
-}
extractFieldTypes : Int -> Mono.MonoType -> List Mono.MonoType
extractFieldTypes n monoType =
    if n <= 0 then
        []

    else
        case monoType of
            Mono.MFunction args result ->
                args ++ extractFieldTypes (n - List.length args) result

            _ ->
                []



-- ========== KERNEL ABI TYPE DERIVATION ==========


{-| Derive the MonoType for a kernel function's ABI.
-}
deriveKernelAbiType : ( String, String ) -> Can.Type -> Substitution -> Mono.MonoType
deriveKernelAbiType kernelId canFuncType callSubst =
    case KernelAbi.deriveKernelAbiMode kernelId canFuncType of
        KernelAbi.UseSubstitution ->
            TypeSubst.applySubst callSubst canFuncType

        KernelAbi.PreserveVars ->
            KernelAbi.canTypeToMonoType_preserveVars canFuncType

        KernelAbi.NumberBoxed ->
            KernelAbi.canTypeToMonoType_numberBoxed canFuncType



-- ========== GLOBAL CONVERSIONS ==========


{-| Convert a typed optimized global reference to a monomorphized global reference.
-}
toptGlobalToMono : TOpt.Global -> Mono.Global
toptGlobalToMono (TOpt.Global canonical name) =
    Mono.Global canonical name
