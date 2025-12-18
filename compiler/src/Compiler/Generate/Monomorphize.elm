module Compiler.Generate.Monomorphize exposing (monomorphize)

{-| Monomorphization Pass

This module transforms a TypedOptimized.GlobalGraph into a Monomorphized.MonoGraph
by specializing all polymorphic functions to their concrete type instantiations.

The algorithm:

1.  Find the entry point (main function)
2.  Use a worklist to process each (Global, MonoType, Maybe LambdaId) tuple
3.  For each work item, specialize the function body by:
    a. Unifying the polymorphic type with the concrete type to get a substitution
    b. Applying the substitution to all types in the expression
    c. Discovering new specializations needed and adding them to the worklist
4.  Continue until the worklist is empty


# Monomorphization

@docs monomorphize

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Optimize.DecisionTree as DT
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import System.TypeCheck.IO as IO



-- ============================================================================
-- STATE
-- ============================================================================


type alias MonoState =
    { worklist : List WorkItem
    , nodes : Dict Int Int Mono.MonoNode
    , inProgress : EverySet Int Int
    , registry : Mono.SpecializationRegistry
    , lambdaCounter : Int
    , currentModule : IO.Canonical
    , toptNodes : Dict (List String) TOpt.Global TOpt.Node
    , currentGlobal : Maybe Mono.Global
    }


type WorkItem
    = SpecializeGlobal Mono.Global Mono.MonoType (Maybe Mono.LambdaId)


initState : IO.Canonical -> Dict (List String) TOpt.Global TOpt.Node -> MonoState
initState currentModule toptNodes =
    { worklist = []
    , nodes = Dict.empty
    , inProgress = EverySet.empty
    , registry = Mono.emptyRegistry
    , lambdaCounter = 0
    , currentModule = currentModule
    , toptNodes = toptNodes
    , currentGlobal = Nothing
    }



-- ============================================================================
-- MAIN ENTRY POINT
-- ============================================================================


{-| Transform a TypedOptimized.GlobalGraph into a fully monomorphized graph by specializing all polymorphic functions to their concrete type instantiations.
-}
monomorphize : TOpt.GlobalGraph -> Result String Mono.MonoGraph
monomorphize (TOpt.GlobalGraph nodes _ _) =
    case findMain nodes of
        Nothing ->
            Err "No main function found"

        Just ( mainGlobal, mainType ) ->
            let
                monoType =
                    canTypeToMonoType Dict.empty mainType

                currentModule =
                    case mainGlobal of
                        TOpt.Global canonical _ ->
                            canonical

                initialState =
                    initState currentModule nodes

                stateWithMain =
                    { initialState
                        | worklist = [ SpecializeGlobal (toptGlobalToMono mainGlobal) monoType Nothing ]
                    }

                finalState =
                    processWorklist stateWithMain

                mainSpecId =
                    let
                        specKey =
                            Mono.toComparableSpecKey (Mono.SpecKey (toptGlobalToMono mainGlobal) monoType Nothing)
                    in
                    Dict.get identity specKey finalState.registry.mapping
            in
            Ok
                (Mono.MonoGraph
                    { nodes = finalState.nodes
                    , main = Maybe.map Mono.StaticMain mainSpecId
                    , registry = finalState.registry
                    }
                )


findMain : Dict (List String) TOpt.Global TOpt.Node -> Maybe ( TOpt.Global, Can.Type )
findMain nodes =
    -- Look for a node with name "main"
    Dict.foldl TOpt.compareGlobal
        (\global node acc ->
            case acc of
                Just _ ->
                    acc

                Nothing ->
                    case ( global, node ) of
                        ( TOpt.Global _ "main", TOpt.Define _ _ tipe ) ->
                            Just ( global, tipe )

                        ( TOpt.Global _ "main", TOpt.TrackedDefine _ _ _ tipe ) ->
                            Just ( global, tipe )

                        _ ->
                            Nothing
        )
        Nothing
        nodes



-- ============================================================================
-- WORKLIST PROCESSING
-- ============================================================================


processWorklist : MonoState -> MonoState
processWorklist state =
    case state.worklist of
        [] ->
            state

        (SpecializeGlobal global monoType maybeLambda) :: rest ->
            let
                -- Get or create specId first
                ( specId, newRegistry ) =
                    Mono.getOrCreateSpecId global monoType maybeLambda state.registry
            in
            if EverySet.member identity specId state.inProgress then
                -- Already being processed, skip to avoid cycles
                processWorklist { state | worklist = rest, registry = newRegistry }

            else if Dict.member identity specId state.nodes then
                -- Already done, skip
                processWorklist { state | worklist = rest, registry = newRegistry }

            else
                -- New specialization to process
                let
                    stateWithId =
                        { state
                            | registry = newRegistry
                            , inProgress = EverySet.insert identity specId state.inProgress
                            , worklist = rest
                        }

                    toptGlobal =
                        monoGlobalToTOpt global
                in
                case Dict.get TOpt.toComparableGlobal toptGlobal state.toptNodes of
                    Nothing ->
                        -- External/kernel function
                        let
                            newState =
                                { stateWithId
                                    | nodes = Dict.insert identity specId (Mono.MonoExtern monoType) stateWithId.nodes
                                    , inProgress = EverySet.remove identity specId stateWithId.inProgress
                                }
                        in
                        processWorklist newState

                    Just toptNode ->
                        -- Specialize the node
                        let
                            -- Set currentGlobal so specializeCycle knows which member was requested
                            stateWithGlobal =
                                { stateWithId | currentGlobal = Just global }

                            ( monoNode, stateAfterSpec ) =
                                specializeNode toptNode monoType stateWithGlobal

                            newState =
                                { stateAfterSpec
                                    | nodes = Dict.insert identity specId monoNode stateAfterSpec.nodes
                                    , inProgress = EverySet.remove identity specId stateAfterSpec.inProgress
                                    , currentGlobal = Nothing
                                }
                        in
                        processWorklist newState



-- ============================================================================
-- NODE SPECIALIZATION
-- ============================================================================


specializeNode : TOpt.Node -> Mono.MonoType -> MonoState -> ( Mono.MonoNode, MonoState )
specializeNode node monoType state =
    case node of
        TOpt.Define expr _ canType ->
            let
                subst =
                    unify canType monoType

                ( monoExpr0, state1 ) =
                    specializeExpr expr subst state

                ( monoExpr, state2 ) =
                    ensureCallableTopLevel monoExpr0 monoType state1
            in
            ( Mono.MonoDefine monoExpr monoType, state2 )

        TOpt.TrackedDefine _ expr _ canType ->
            let
                subst =
                    unify canType monoType

                ( monoExpr0, state1 ) =
                    specializeExpr expr subst state

                ( monoExpr, state2 ) =
                    ensureCallableTopLevel monoExpr0 monoType state1
            in
            ( Mono.MonoDefine monoExpr monoType, state2 )

        TOpt.DefineTailFunc _ args body _ returnType ->
            let
                funcType =
                    buildFuncType args returnType

                subst =
                    unify funcType monoType

                monoArgs =
                    List.map (specializeArg subst) args

                ( monoBody, stateAfter ) =
                    specializeExpr body subst state

                monoReturnType =
                    applySubst subst returnType
            in
            ( Mono.MonoTailFunc monoArgs monoBody monoReturnType, stateAfter )

        TOpt.Ctor index arity _ ->
            let
                ctorIndex =
                    Index.toMachine index

                layout =
                    buildCtorLayoutFromArity ctorIndex arity monoType

                ctorResultType =
                    extractCtorResultType arity monoType
            in
            ( Mono.MonoCtor layout ctorResultType, state )

        TOpt.Enum index _ ->
            let
                tag =
                    Index.toMachine index
            in
            ( Mono.MonoEnum tag monoType, state )

        TOpt.Box _ ->
            ( Mono.MonoExtern monoType, state )

        TOpt.Link linkedGlobal ->
            -- Follow the link to the actual definition
            case Dict.get TOpt.toComparableGlobal linkedGlobal state.toptNodes of
                Nothing ->
                    -- Linked global not found, treat as extern
                    ( Mono.MonoExtern monoType, state )

                Just linkedNode ->
                    -- Specialize the linked node
                    specializeNode linkedNode monoType state

        TOpt.Cycle names values functions _ ->
            -- Specialize all definitions in the cycle and return MonoCycle
            specializeCycle names values functions monoType state

        TOpt.Manager _ ->
            ( Mono.MonoExtern monoType, state )

        TOpt.Kernel _ _ ->
            ( Mono.MonoExtern monoType, state )

        TOpt.PortIncoming expr _ canType ->
            let
                subst =
                    unify canType monoType

                ( monoExpr0, state1 ) =
                    specializeExpr expr subst state

                ( monoExpr, state2 ) =
                    ensureCallableTopLevel monoExpr0 monoType state1
            in
            ( Mono.MonoPortIncoming monoExpr monoType, state2 )

        TOpt.PortOutgoing expr _ canType ->
            let
                subst =
                    unify canType monoType

                ( monoExpr0, state1 ) =
                    specializeExpr expr subst state

                ( monoExpr, state2 ) =
                    ensureCallableTopLevel monoExpr0 monoType state1
            in
            ( Mono.MonoPortOutgoing monoExpr monoType, state2 )


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



-- ============================================================================
-- CYCLE SPECIALIZATION
-- ============================================================================


{-| Specialize all definitions in a cycle.

For function cycles, we:

1.  Identify which function was requested via state.currentGlobal
2.  Build a shared substitution from the requested function's type
3.  Generate MonoTailFunc/MonoDefine for ALL function members (not MonoCycle)
4.  Register each with its own specId in state.nodes
5.  Return the node for the originally requested function

For value-only cycles, we still use MonoCycle bundling.

-}
specializeCycle :
    List Name
    -> List ( Name, TOpt.Expr )
    -> List TOpt.Def
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoNode, MonoState )
specializeCycle names values functions requestedMonoType state =
    case ( List.isEmpty functions, state.currentGlobal ) of
        ( True, _ ) ->
            -- Value-only cycle: use old bundling behavior
            specializeValueOnlyCycle names values requestedMonoType state

        ( False, Nothing ) ->
            -- No currentGlobal set - fallback to extern (shouldn't happen)
            ( Mono.MonoExtern requestedMonoType, state )

        ( False, Just (Mono.Global requestedCanonical requestedName) ) ->
            -- Function cycle: generate proper MonoTailFunc/MonoDefine nodes
            specializeFunctionCycle requestedCanonical requestedName functions requestedMonoType state


{-| Specialize a value-only cycle using the old bundling behavior.
-}
specializeValueOnlyCycle :
    List Name
    -> List ( Name, TOpt.Expr )
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoNode, MonoState )
specializeValueOnlyCycle _ values monoType state =
    let
        subst =
            Dict.empty

        ( monoValues, state1 ) =
            specializeValueDefs values subst state
    in
    ( Mono.MonoCycle monoValues monoType, state1 )


{-| Specialize a function cycle by generating separate MonoTailFunc/MonoDefine nodes.
-}
specializeFunctionCycle :
    IO.Canonical
    -> Name
    -> List TOpt.Def
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoNode, MonoState )
specializeFunctionCycle requestedCanonical requestedName functions requestedMonoType state =
    let
        -- Find the requested function definition
        maybeRequestedDef =
            List.filter (defHasName requestedName) functions
                |> List.head

        -- Get the canonical type for the requested function and build substitution
        subst =
            case maybeRequestedDef of
                Just def ->
                    let
                        canType =
                            getDefCanonicalType def
                    in
                    unify canType requestedMonoType

                Nothing ->
                    -- Requested function not found in cycle - use empty subst
                    Dict.empty

        -- Process all function definitions and register them as nodes
        ( funcNameSpecIds, stateAfterFuncs ) =
            List.foldl
                (\def ( acc, st ) ->
                    let
                        name =
                            getDefName def

                        -- Build the global for this member
                        memberGlobal =
                            Mono.Global requestedCanonical name

                        -- Compute member's mono type
                        memberCanType =
                            getDefCanonicalType def

                        memberMonoType =
                            applySubst subst memberCanType

                        -- Get or create specId for this member
                        ( specId, newRegistry ) =
                            Mono.getOrCreateSpecId memberGlobal memberMonoType Nothing st.registry

                        -- Specialize this function as a proper node
                        ( monoNode, st1 ) =
                            specializeFuncNodeInCycle subst def { st | registry = newRegistry }

                        -- Insert the node into state.nodes
                        st2 =
                            { st1
                                | nodes = Dict.insert identity specId monoNode st1.nodes
                            }
                    in
                    ( ( name, specId ) :: acc, st2 )
                )
                ( [], state )
                functions

        -- Find and return the node for the requested function
        maybeRequestedSpecId =
            List.filter (\( name, _ ) -> name == requestedName) funcNameSpecIds
                |> List.head
                |> Maybe.map Tuple.second
    in
    case maybeRequestedSpecId of
        Just requestedSpecId ->
            case Dict.get identity requestedSpecId stateAfterFuncs.nodes of
                Just requestedNode ->
                    ( requestedNode, stateAfterFuncs )

                Nothing ->
                    -- Node not found (shouldn't happen)
                    ( Mono.MonoExtern requestedMonoType, stateAfterFuncs )

        Nothing ->
            -- Requested function not in cycle (shouldn't happen)
            ( Mono.MonoExtern requestedMonoType, stateAfterFuncs )


{-| Specialize a function definition in a cycle as a proper MonoTailFunc/MonoDefine node.
-}
specializeFuncNodeInCycle :
    Substitution
    -> TOpt.Def
    -> MonoState
    -> ( Mono.MonoNode, MonoState )
specializeFuncNodeInCycle subst def state =
    case def of
        TOpt.Def _ _ expr canType ->
            -- Regular function definition
            let
                monoType =
                    applySubst subst canType

                ( monoExpr, state1 ) =
                    specializeExpr expr subst state
            in
            ( Mono.MonoDefine monoExpr monoType, state1 )

        TOpt.TailDef _ _ args body returnType ->
            -- Tail-recursive function definition
            let
                monoArgs =
                    List.map (specializeArg subst) args

                ( monoBody, state1 ) =
                    specializeExpr body subst state

                monoReturnType =
                    applySubst subst returnType
            in
            ( Mono.MonoTailFunc monoArgs monoBody monoReturnType, state1 )


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


{-| Specialize a list of value definitions (name, expr pairs).
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



-- ============================================================================
-- EXPRESSION SPECIALIZATION
-- ============================================================================


specializeExpr : TOpt.Expr -> Substitution -> MonoState -> ( Mono.MonoExpr, MonoState )
specializeExpr expr subst state =
    case expr of
        TOpt.Bool _ value _ ->
            ( Mono.MonoLiteral (Mono.LBool value) Mono.MBool, state )

        TOpt.Chr _ value _ ->
            ( Mono.MonoLiteral (Mono.LChar value) Mono.MChar, state )

        TOpt.Str _ value _ ->
            ( Mono.MonoLiteral (Mono.LStr value) Mono.MString, state )

        TOpt.Int _ value _ ->
            ( Mono.MonoLiteral (Mono.LInt value) Mono.MInt, state )

        TOpt.Float _ value _ ->
            ( Mono.MonoLiteral (Mono.LFloat value) Mono.MFloat, state )

        TOpt.VarLocal name canType ->
            let
                monoType =
                    applySubst subst canType
            in
            ( Mono.MonoVarLocal name monoType, state )

        TOpt.TrackedVarLocal _ name canType ->
            let
                monoType =
                    applySubst subst canType
            in
            ( Mono.MonoVarLocal name monoType, state )

        TOpt.VarGlobal region global canType ->
            let
                monoType =
                    applySubst subst canType

                monoGlobal =
                    toptGlobalToMono global

                ( specId, newRegistry ) =
                    Mono.getOrCreateSpecId monoGlobal monoType Nothing state.registry

                workItem =
                    SpecializeGlobal monoGlobal monoType Nothing

                newState =
                    { state
                        | registry = newRegistry
                        , worklist = workItem :: state.worklist
                    }
            in
            ( Mono.MonoVarGlobal region specId monoType, newState )

        TOpt.VarEnum region global _ canType ->
            let
                monoType =
                    applySubst subst canType

                monoGlobal =
                    toptGlobalToMono global

                ( specId, newRegistry ) =
                    Mono.getOrCreateSpecId monoGlobal monoType Nothing state.registry

                workItem =
                    SpecializeGlobal monoGlobal monoType Nothing

                newState =
                    { state
                        | registry = newRegistry
                        , worklist = workItem :: state.worklist
                    }
            in
            ( Mono.MonoVarGlobal region specId monoType, newState )

        TOpt.VarBox region global canType ->
            let
                monoType =
                    applySubst subst canType

                monoGlobal =
                    toptGlobalToMono global

                ( specId, newRegistry ) =
                    Mono.getOrCreateSpecId monoGlobal monoType Nothing state.registry

                workItem =
                    SpecializeGlobal monoGlobal monoType Nothing

                newState =
                    { state
                        | registry = newRegistry
                        , worklist = workItem :: state.worklist
                    }
            in
            ( Mono.MonoVarGlobal region specId monoType, newState )

        TOpt.VarCycle region canonical name canType ->
            let
                monoType =
                    applySubst subst canType

                monoGlobal =
                    Mono.Global canonical name

                ( specId, newRegistry ) =
                    Mono.getOrCreateSpecId monoGlobal monoType Nothing state.registry

                workItem =
                    SpecializeGlobal monoGlobal monoType Nothing

                newState =
                    { state
                        | registry = newRegistry
                        , worklist = workItem :: state.worklist
                    }
            in
            ( Mono.MonoVarGlobal region specId monoType, newState )

        TOpt.VarDebug region name _ _ canType ->
            let
                monoType =
                    applySubst subst canType
            in
            ( Mono.MonoVarKernel region "Debug" name monoType, state )

        TOpt.VarKernel region home name canType ->
            let
                monoType =
                    applySubst subst canType
            in
            ( Mono.MonoVarKernel region home name monoType, state )

        TOpt.List region exprs canType ->
            let
                monoType =
                    applySubst subst canType

                ( monoExprs, stateAfter ) =
                    specializeExprs exprs subst state
            in
            ( Mono.MonoList region monoExprs monoType, stateAfter )

        TOpt.Function params body canType ->
            let
                monoType =
                    applySubst subst canType

                monoParams =
                    List.map (\( name, t ) -> ( name, applySubst subst t )) params

                -- Allocate a lambda ID
                lambdaId =
                    Mono.AnonymousLambda state.currentModule state.lambdaCounter

                stateWithLambda =
                    { state | lambdaCounter = state.lambdaCounter + 1 }

                ( monoBody, stateAfter ) =
                    specializeExpr body subst stateWithLambda

                -- Compute free variables in the body, excluding the params
                boundByParams =
                    List.foldl (\( n, _ ) acc -> EverySet.insert identity n acc) EverySet.empty monoParams

                captures =
                    findFreeVars boundByParams monoBody
                        |> dedupeCaptures

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
                    applySubst subst canType

                monoParams =
                    List.map (\( locName, t ) -> ( A.toValue locName, applySubst subst t )) params

                lambdaId =
                    Mono.AnonymousLambda state.currentModule state.lambdaCounter

                stateWithLambda =
                    { state | lambdaCounter = state.lambdaCounter + 1 }

                ( monoBody, stateAfter ) =
                    specializeExpr body subst stateWithLambda

                -- Compute free variables in the body, excluding the params
                boundByParams =
                    List.foldl (\( n, _ ) acc -> EverySet.insert identity n acc) EverySet.empty monoParams

                captures =
                    findFreeVars boundByParams monoBody
                        |> dedupeCaptures

                closureInfo =
                    { lambdaId = lambdaId
                    , captures = captures
                    , params = monoParams
                    }
            in
            ( Mono.MonoClosure closureInfo monoBody monoType, stateAfter )

        TOpt.Call region func args canType ->
            let
                ( monoArgs, state1 ) =
                    specializeExprs args subst state

                ( monoFunc, resultMonoType, state2 ) =
                    case func of
                        -- IMPORTANT: instantiate polymorphic globals using (args, result)
                        TOpt.VarGlobal funcRegion global funcCanType ->
                            let
                                -- First, infer substitutions from argument types only.
                                argTypes =
                                    List.map Mono.typeOf monoArgs

                                substFromArgs =
                                    unifyArgsOnly funcCanType argTypes Dict.empty

                                subst2 =
                                    mergeSubst subst substFromArgs

                                -- Now we can safely compute the call result type.
                                callResultMonoType =
                                    applySubst subst2 canType

                                -- Optionally refine further using args+result (keeps things consistent)
                                substFromArgsAndResult =
                                    inferCallSubst funcCanType monoArgs callResultMonoType

                                subst3 =
                                    mergeSubst subst2 substFromArgsAndResult

                                funcMonoType =
                                    applySubst subst3 funcCanType

                                monoGlobal =
                                    toptGlobalToMono global

                                ( specId, newRegistry ) =
                                    Mono.getOrCreateSpecId monoGlobal funcMonoType Nothing state1.registry

                                workItem =
                                    SpecializeGlobal monoGlobal funcMonoType Nothing

                                newState =
                                    { state1
                                        | registry = newRegistry
                                        , worklist = workItem :: state1.worklist
                                    }
                            in
                            ( Mono.MonoVarGlobal funcRegion specId funcMonoType, callResultMonoType, newState )

                        -- IMPORTANT: instantiate polymorphic kernel functions using (args, result)
                        TOpt.VarKernel funcRegion home name funcCanType ->
                            let
                                -- First, infer substitutions from argument types only.
                                argTypes =
                                    List.map Mono.typeOf monoArgs

                                substFromArgs =
                                    unifyArgsOnly funcCanType argTypes Dict.empty

                                subst2 =
                                    mergeSubst subst substFromArgs

                                -- Now we can safely compute the call result type.
                                callResultMonoType =
                                    applySubst subst2 canType

                                -- Optionally refine further using args+result (keeps things consistent)
                                substFromArgsAndResult =
                                    inferCallSubst funcCanType monoArgs callResultMonoType

                                subst3 =
                                    mergeSubst subst2 substFromArgsAndResult

                                funcMonoType =
                                    applySubst subst3 funcCanType
                            in
                            ( Mono.MonoVarKernel funcRegion home name funcMonoType, callResultMonoType, state1 )

                        -- fallback: old behavior
                        _ ->
                            let
                                ( mFunc, st ) =
                                    specializeExpr func subst state1

                                fallbackResultMonoType =
                                    applySubst subst canType
                            in
                            ( mFunc, fallbackResultMonoType, st )

                -- Check for lambda specialization opportunity
                ( finalFunc, state3 ) =
                    maybeSpecializeForLambda monoFunc monoArgs state2
            in
            ( Mono.MonoCall region finalFunc monoArgs resultMonoType, state3 )

        TOpt.TailCall name args canType ->
            let
                monoType =
                    applySubst subst canType

                ( monoArgs, stateAfter ) =
                    specializeNamedExprs args subst state
            in
            ( Mono.MonoTailCall name monoArgs monoType, stateAfter )

        TOpt.If branches final canType ->
            let
                monoType =
                    applySubst subst canType

                ( monoBranches, state1 ) =
                    specializeBranches branches subst state

                ( monoFinal, state2 ) =
                    specializeExpr final subst state1
            in
            ( Mono.MonoIf monoBranches monoFinal monoType, state2 )

        TOpt.Let def body canType ->
            let
                monoType =
                    applySubst subst canType

                ( monoDef, state1 ) =
                    specializeDef def subst state

                ( monoBody, state2 ) =
                    specializeExpr body subst state1
            in
            ( Mono.MonoLet monoDef monoBody monoType, state2 )

        TOpt.Destruct destructor body canType ->
            let
                monoType =
                    applySubst subst canType

                monoDestructor =
                    specializeDestructor destructor subst

                ( monoBody, stateAfter ) =
                    specializeExpr body subst state
            in
            ( Mono.MonoDestruct monoDestructor monoBody monoType, stateAfter )

        TOpt.Case label root decider jumps canType ->
            let
                monoType =
                    applySubst subst canType

                ( monoDecider, state1 ) =
                    specializeDecider decider subst state

                ( monoJumps, state2 ) =
                    specializeJumps jumps subst state1
            in
            ( Mono.MonoCase label root monoDecider monoJumps monoType, state2 )

        TOpt.Accessor region fieldName canType ->
            let
                monoType =
                    applySubst subst canType
            in
            ( Mono.MonoAccessor region fieldName monoType, state )

        TOpt.Access record _ fieldName canType ->
            let
                monoType =
                    applySubst subst canType

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
                    applySubst subst canType

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
                    applySubst subst canType

                layout =
                    getRecordLayout monoType

                ( monoFields, stateAfter ) =
                    specializeRecordFields fields layout subst state
            in
            ( Mono.MonoRecordCreate monoFields layout monoType, stateAfter )

        TOpt.TrackedRecord _ fields canType ->
            let
                monoType =
                    applySubst subst canType

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
                    applySubst subst canType

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
            -- Shaders are not supported in MLIR backend
            ( Mono.MonoUnit, state )



-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================


specializeExprs : List TOpt.Expr -> Substitution -> MonoState -> ( List Mono.MonoExpr, MonoState )
specializeExprs exprs subst state =
    List.foldr
        (\expr ( acc, st ) ->
            let
                ( monoExpr, newSt ) =
                    specializeExpr expr subst st
            in
            ( monoExpr :: acc, newSt )
        )
        ( [], state )
        exprs


specializeNamedExprs : List ( Name, TOpt.Expr ) -> Substitution -> MonoState -> ( List ( Name, Mono.MonoExpr ), MonoState )
specializeNamedExprs namedExprs subst state =
    List.foldr
        (\( name, expr ) ( acc, st ) ->
            let
                ( monoExpr, newSt ) =
                    specializeExpr expr subst st
            in
            ( ( name, monoExpr ) :: acc, newSt )
        )
        ( [], state )
        namedExprs


specializeBranches : List ( TOpt.Expr, TOpt.Expr ) -> Substitution -> MonoState -> ( List ( Mono.MonoExpr, Mono.MonoExpr ), MonoState )
specializeBranches branches subst state =
    List.foldr
        (\( cond, body ) ( acc, st ) ->
            let
                ( monoCond, st1 ) =
                    specializeExpr cond subst st

                ( monoBody, st2 ) =
                    specializeExpr body subst st1
            in
            ( ( monoCond, monoBody ) :: acc, st2 )
        )
        ( [], state )
        branches


specializeDef : TOpt.Def -> Substitution -> MonoState -> ( Mono.MonoDef, MonoState )
specializeDef def subst state =
    case def of
        TOpt.Def _ name expr _ ->
            let
                ( monoExpr, stateAfter ) =
                    specializeExpr expr subst state
            in
            ( Mono.MonoDef name monoExpr, stateAfter )

        TOpt.TailDef _ name _ expr _ ->
            let
                ( monoExpr, stateAfter ) =
                    specializeExpr expr subst state
            in
            ( Mono.MonoTailDef name monoExpr, stateAfter )


specializeDestructor : TOpt.Destructor -> Substitution -> Mono.MonoDestructor
specializeDestructor (TOpt.Destructor name path _) _ =
    let
        monoPath =
            specializePath path
    in
    Mono.MonoDestructor name monoPath


specializePath : TOpt.Path -> Mono.MonoPath
specializePath path =
    case path of
        TOpt.Index index subPath ->
            Mono.MonoIndex (Index.toMachine index) (specializePath subPath)

        TOpt.ArrayIndex idx subPath ->
            -- Treat array index as regular index for now
            Mono.MonoIndex idx (specializePath subPath)

        TOpt.Field _ subPath ->
            -- Field access needs index lookup at runtime
            Mono.MonoField 0 (specializePath subPath)

        TOpt.Unbox subPath ->
            Mono.MonoUnbox (specializePath subPath)

        TOpt.Root name ->
            Mono.MonoRoot name


specializeDecider : TOpt.Decider TOpt.Choice -> Substitution -> MonoState -> ( Mono.Decider Mono.MonoChoice, MonoState )
specializeDecider decider subst state =
    case decider of
        TOpt.Leaf choice ->
            let
                ( monoChoice, stateAfter ) =
                    specializeChoice choice subst state
            in
            ( Mono.Leaf monoChoice, stateAfter )

        TOpt.Chain _ success failure ->
            let
                ( monoSuccess, state1 ) =
                    specializeDecider success subst state

                ( monoFailure, state2 ) =
                    specializeDecider failure subst state1
            in
            ( Mono.Chain monoSuccess monoFailure, state2 )

        TOpt.FanOut _ edges fallback ->
            let
                ( monoEdges, state1 ) =
                    specializeEdges edges subst state

                ( monoFallback, state2 ) =
                    specializeDecider fallback subst state1
            in
            ( Mono.FanOut monoEdges monoFallback, state2 )


specializeChoice : TOpt.Choice -> Substitution -> MonoState -> ( Mono.MonoChoice, MonoState )
specializeChoice choice subst state =
    case choice of
        TOpt.Inline expr ->
            let
                ( monoExpr, stateAfter ) =
                    specializeExpr expr subst state
            in
            ( Mono.Inline monoExpr, stateAfter )

        TOpt.Jump _ ->
            ( Mono.Jump, state )


specializeEdges : List ( DT.Test, TOpt.Decider TOpt.Choice ) -> Substitution -> MonoState -> ( List ( DT.Test, Mono.Decider Mono.MonoChoice ), MonoState )
specializeEdges edges subst state =
    List.foldr
        (\( test, decider ) ( acc, st ) ->
            let
                ( monoDecider, newSt ) =
                    specializeDecider decider subst st
            in
            ( ( test, monoDecider ) :: acc, newSt )
        )
        ( [], state )
        edges


specializeJumps : List ( Int, TOpt.Expr ) -> Substitution -> MonoState -> ( List ( Int, Mono.MonoExpr ), MonoState )
specializeJumps jumps subst state =
    List.foldr
        (\( idx, expr ) ( acc, st ) ->
            let
                ( monoExpr, newSt ) =
                    specializeExpr expr subst st
            in
            ( ( idx, monoExpr ) :: acc, newSt )
        )
        ( [], state )
        jumps


specializeRecordFields : Dict String Name TOpt.Expr -> Mono.RecordLayout -> Substitution -> MonoState -> ( List Mono.MonoExpr, MonoState )
specializeRecordFields fields layout subst state =
    -- Fields need to be in layout order
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
                    -- Field not found, this shouldn't happen
                    ( Mono.MonoUnit :: acc, st )
        )
        ( [], state )
        layout.fields


specializeTrackedRecordFields : Dict String (A.Located Name) TOpt.Expr -> Mono.RecordLayout -> Substitution -> MonoState -> ( List Mono.MonoExpr, MonoState )
specializeTrackedRecordFields fields layout subst state =
    let
        -- Convert A.Located Name keyed dict to String keyed dict
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


specializeArg : Substitution -> ( A.Located Name, Can.Type ) -> ( Name, Mono.MonoType )
specializeArg subst ( locName, canType ) =
    ( A.toValue locName, applySubst subst canType )



-- ============================================================================
-- LAMBDA SPECIALIZATION
-- ============================================================================


maybeSpecializeForLambda : Mono.MonoExpr -> List Mono.MonoExpr -> MonoState -> ( Mono.MonoExpr, MonoState )
maybeSpecializeForLambda func args state =
    case func of
        Mono.MonoVarGlobal region specId funcType ->
            case detectLambdaArg args of
                Just lambdaId ->
                    -- Create a lambda-specialized version
                    case Mono.lookupSpecKey specId state.registry of
                        Just ( global, monoType, _ ) ->
                            let
                                ( newSpecId, newRegistry ) =
                                    Mono.getOrCreateSpecId global monoType (Just lambdaId) state.registry

                                workItem =
                                    SpecializeGlobal global monoType (Just lambdaId)

                                newState =
                                    { state
                                        | registry = newRegistry
                                        , worklist = workItem :: state.worklist
                                    }
                            in
                            ( Mono.MonoVarGlobal region newSpecId funcType, newState )

                        Nothing ->
                            ( func, state )

                Nothing ->
                    ( func, state )

        _ ->
            ( func, state )


detectLambdaArg : List Mono.MonoExpr -> Maybe Mono.LambdaId
detectLambdaArg args =
    case args of
        (Mono.MonoClosure info _ _) :: _ ->
            Just info.lambdaId

        (Mono.MonoVarGlobal _ _ _) :: _ ->
            -- This could be a named function passed as argument
            -- For now, we don't specialize for named function args
            Nothing

        _ ->
            Nothing



-- ============================================================================
-- ETA-EXPANSION FOR TOP-LEVEL FUNCTION DEFINITIONS
-- ============================================================================


{-| Ensure that a top-level definition with function type has a callable body.

For any MonoDefine whose monoType is MFunction, its body must be a MonoClosure
so backends never need to special-case MonoVarGlobal of function type.

This handles eta-reduced definitions like:
text = VirtualDom.text

By expanding them to:
text = \\arg0 -> VirtualDom.text arg0

-}
ensureCallableTopLevel : Mono.MonoExpr -> Mono.MonoType -> MonoState -> ( Mono.MonoExpr, MonoState )
ensureCallableTopLevel expr monoType state =
    case monoType of
        Mono.MFunction _ _ ->
            let
                -- Flatten curried function type to get all argument types
                ( allArgTypes, finalRetType ) =
                    flattenFunctionType monoType
            in
            case expr of
                Mono.MonoClosure closureInfo body _ ->
                    -- Check if the closure's params are sufficient for the expected arity
                    if List.length closureInfo.params >= List.length allArgTypes then
                        -- Closure has enough params (or more for partial application context)
                        -- Use as-is; partial application will be handled at call sites
                        ( expr, state )

                    else
                        -- Closure has fewer params than expected (eta-reduced alias case)
                        -- The body should be a callable function value, wrap it
                        -- Preserve the original captures
                        makeGeneralClosureWithCaptures body closureInfo.captures allArgTypes finalRetType monoType state

                Mono.MonoVarGlobal region specId _ ->
                    makeAliasClosure
                        (Mono.MonoVarGlobal region specId monoType)
                        region
                        allArgTypes
                        finalRetType
                        monoType
                        state

                Mono.MonoVarKernel region home name _ ->
                    makeAliasClosure
                        (Mono.MonoVarKernel region home name monoType)
                        region
                        allArgTypes
                        finalRetType
                        monoType
                        state

                _ ->
                    -- General fallback for other cases (MonoVarDebug, MonoAccessor, etc.)
                    makeGeneralClosure expr allArgTypes finalRetType monoType state

        _ ->
            -- Not a function type, leave unchanged
            ( expr, state )


{-| Flatten a curried function type to get all argument types and the final return type.

    MFunction [ A ] (MFunction [ B ] C) => ( [ A, B ], C )

-}
flattenFunctionType : Mono.MonoType -> ( List Mono.MonoType, Mono.MonoType )
flattenFunctionType monoType =
    case monoType of
        Mono.MFunction argTypes retType ->
            let
                ( moreArgs, finalRet ) =
                    flattenFunctionType retType
            in
            ( argTypes ++ moreArgs, finalRet )

        _ ->
            ( [], monoType )


{-| Create a closure that wraps a callee expression with eta-expansion.

Given a callee like `VirtualDom.text` with type `String -> Html`,
creates: `\arg0 -> VirtualDom.text arg0`

-}
makeAliasClosure :
    Mono.MonoExpr
    -> A.Region
    -> List Mono.MonoType
    -> Mono.MonoType
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoExpr, MonoState )
makeAliasClosure calleeExpr region argTypes retType monoType state =
    let
        -- Generate fresh parameter names
        params : List ( Name, Mono.MonoType )
        params =
            freshParams argTypes

        -- Create parameter expressions for the call
        paramExprs : List Mono.MonoExpr
        paramExprs =
            List.map
                (\( name, ty ) -> Mono.MonoVarLocal name ty)
                params

        -- Allocate a lambda ID
        lambdaId : Mono.LambdaId
        lambdaId =
            Mono.AnonymousLambda state.currentModule state.lambdaCounter

        stateWithLambda : MonoState
        stateWithLambda =
            { state | lambdaCounter = state.lambdaCounter + 1 }

        -- Build the call to the aliased function
        callExpr : Mono.MonoExpr
        callExpr =
            Mono.MonoCall region calleeExpr paramExprs retType

        -- Assemble the closure
        closureInfo : Mono.ClosureInfo
        closureInfo =
            { lambdaId = lambdaId
            , captures = []
            , params = params
            }

        closureExpr : Mono.MonoExpr
        closureExpr =
            Mono.MonoClosure closureInfo callExpr monoType
    in
    ( closureExpr, stateWithLambda )


{-| Create a closure that wraps an arbitrary expression with eta-expansion.

This is the general fallback for cases where the expression isn't a simple
variable reference. It evaluates the expression and calls it with the params.

-}
makeGeneralClosure :
    Mono.MonoExpr
    -> List Mono.MonoType
    -> Mono.MonoType
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoExpr, MonoState )
makeGeneralClosure expr argTypes retType monoType state =
    let
        -- Try to extract a region from the expression, fall back to zero
        region : A.Region
        region =
            extractRegion expr

        -- Generate fresh parameter names
        params : List ( Name, Mono.MonoType )
        params =
            freshParams argTypes

        -- Create parameter expressions for the call
        paramExprs : List Mono.MonoExpr
        paramExprs =
            List.map
                (\( name, ty ) -> Mono.MonoVarLocal name ty)
                params

        -- Allocate a lambda ID
        lambdaId : Mono.LambdaId
        lambdaId =
            Mono.AnonymousLambda state.currentModule state.lambdaCounter

        stateWithLambda : MonoState
        stateWithLambda =
            { state | lambdaCounter = state.lambdaCounter + 1 }

        -- Build the call: expr(arg0, arg1, ...)
        callExpr : Mono.MonoExpr
        callExpr =
            Mono.MonoCall region expr paramExprs retType

        -- Assemble the closure
        closureInfo : Mono.ClosureInfo
        closureInfo =
            { lambdaId = lambdaId
            , captures = []
            , params = params
            }

        closureExpr : Mono.MonoExpr
        closureExpr =
            Mono.MonoClosure closureInfo callExpr monoType
    in
    ( closureExpr, stateWithLambda )


{-| Like makeGeneralClosure but preserves existing captures from an outer closure.
-}
makeGeneralClosureWithCaptures :
    Mono.MonoExpr
    -> List ( Name, Mono.MonoExpr, Bool )
    -> List Mono.MonoType
    -> Mono.MonoType
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoExpr, MonoState )
makeGeneralClosureWithCaptures expr captures argTypes retType monoType state =
    let
        -- Try to extract a region from the expression, fall back to zero
        region : A.Region
        region =
            extractRegion expr

        -- Generate fresh parameter names
        params : List ( Name, Mono.MonoType )
        params =
            freshParams argTypes

        -- Create parameter expressions for the call
        paramExprs : List Mono.MonoExpr
        paramExprs =
            List.map
                (\( name, ty ) -> Mono.MonoVarLocal name ty)
                params

        -- Allocate a lambda ID
        lambdaId : Mono.LambdaId
        lambdaId =
            Mono.AnonymousLambda state.currentModule state.lambdaCounter

        stateWithLambda : MonoState
        stateWithLambda =
            { state | lambdaCounter = state.lambdaCounter + 1 }

        -- Build the call: expr(arg0, arg1, ...)
        callExpr : Mono.MonoExpr
        callExpr =
            Mono.MonoCall region expr paramExprs retType

        -- Assemble the closure - preserve the captures!
        closureInfo : Mono.ClosureInfo
        closureInfo =
            { lambdaId = lambdaId
            , captures = captures
            , params = params
            }

        closureExpr : Mono.MonoExpr
        closureExpr =
            Mono.MonoClosure closureInfo callExpr monoType
    in
    ( closureExpr, stateWithLambda )


{-| Generate fresh parameter names for eta-expansion.
-}
freshParams : List Mono.MonoType -> List ( Name, Mono.MonoType )
freshParams argTypes =
    List.indexedMap
        (\i ty -> ( "arg" ++ String.fromInt i, ty ))
        argTypes


{-| Extract a region from a MonoExpr, falling back to A.zero if none available.
-}
extractRegion : Mono.MonoExpr -> A.Region
extractRegion expr =
    case expr of
        Mono.MonoLiteral _ _ ->
            A.zero

        Mono.MonoVarLocal _ _ ->
            A.zero

        Mono.MonoVarGlobal region _ _ ->
            region

        Mono.MonoVarKernel region _ _ _ ->
            region

        Mono.MonoList region _ _ ->
            region

        Mono.MonoClosure _ _ _ ->
            A.zero

        Mono.MonoCall region _ _ _ ->
            region

        Mono.MonoTailCall _ _ _ ->
            A.zero

        Mono.MonoIf _ _ _ ->
            A.zero

        Mono.MonoLet _ _ _ ->
            A.zero

        Mono.MonoDestruct _ _ _ ->
            A.zero

        Mono.MonoCase _ _ _ _ _ ->
            A.zero

        Mono.MonoRecordCreate _ _ _ ->
            A.zero

        Mono.MonoRecordAccess _ _ _ _ _ ->
            A.zero

        Mono.MonoRecordUpdate _ _ _ _ ->
            A.zero

        Mono.MonoTupleCreate region _ _ _ ->
            region

        Mono.MonoUnit ->
            A.zero

        Mono.MonoAccessor region _ _ ->
            region



-- ============================================================================
-- TYPE UNIFICATION AND SUBSTITUTION
-- ============================================================================


type alias Substitution =
    Dict String Name Mono.MonoType


unify : Can.Type -> Mono.MonoType -> Substitution
unify canType monoType =
    unifyHelp canType monoType Dict.empty


unifyHelp : Can.Type -> Mono.MonoType -> Substitution -> Substitution
unifyHelp canType monoType subst =
    case ( canType, monoType ) of
        ( Can.TVar name, _ ) ->
            Dict.insert identity name monoType subst

        ( Can.TLambda from to, Mono.MFunction args ret ) ->
            case args of
                [] ->
                    subst

                firstArg :: restArgs ->
                    let
                        subst1 =
                            unifyHelp from firstArg subst
                    in
                    if List.isEmpty restArgs then
                        unifyHelp to ret subst1

                    else
                        unifyHelp to (Mono.MFunction restArgs ret) subst1

        ( Can.TType _ _ args, Mono.MCustom _ _ monoArgs ) ->
            List.foldl
                (\( canArg, monoArg ) s ->
                    unifyHelp canArg monoArg s
                )
                subst
                (List.map2 Tuple.pair args monoArgs)

        ( Can.TType _ _ args, Mono.MList innerType ) ->
            case args of
                [ elemType ] ->
                    unifyHelp elemType innerType subst

                _ ->
                    subst

        ( Can.TRecord fields _, Mono.MRecord layout ) ->
            List.foldl
                (\fieldInfo s ->
                    case Dict.get identity fieldInfo.name fields of
                        Just (Can.FieldType _ fieldType) ->
                            unifyHelp fieldType fieldInfo.monoType s

                        Nothing ->
                            s
                )
                subst
                layout.fields

        ( Can.TTuple a b rest, Mono.MTuple layout ) ->
            let
                canTypes =
                    a :: b :: rest

                monoTypes =
                    List.map Tuple.first layout.elements
            in
            List.foldl
                (\( canT, monoT ) s ->
                    unifyHelp canT monoT s
                )
                subst
                (List.map2 Tuple.pair canTypes monoTypes)

        ( Can.TAlias _ _ _ (Can.Filled inner), _ ) ->
            unifyHelp inner monoType subst

        ( Can.TAlias _ _ args (Can.Holey inner), _ ) ->
            let
                argSubst =
                    List.foldl
                        (\( _, t ) s ->
                            unifyHelp t (applySubst s t) s
                        )
                        subst
                        args
            in
            unifyHelp inner monoType argSubst

        _ ->
            subst


mergeSubst : Substitution -> Substitution -> Substitution
mergeSubst base extra =
    Dict.foldl compare
        (\k v acc -> Dict.insert identity k v acc)
        base
        extra


inferCallSubst : Can.Type -> List Mono.MonoExpr -> Mono.MonoType -> Substitution
inferCallSubst funcCanType monoArgs resultMonoType =
    let
        argTypes : List Mono.MonoType
        argTypes =
            List.map Mono.typeOf monoArgs

        desiredFuncType : Mono.MonoType
        desiredFuncType =
            Mono.MFunction argTypes resultMonoType
    in
    unify funcCanType desiredFuncType


unifyArgsOnly : Can.Type -> List Mono.MonoType -> Substitution -> Substitution
unifyArgsOnly canFuncType argTypes subst =
    case ( canFuncType, argTypes ) of
        ( _, [] ) ->
            subst

        ( Can.TLambda from to, arg0 :: rest ) ->
            let
                subst1 =
                    unifyHelp from arg0 subst
            in
            unifyArgsOnly to rest subst1

        -- If we run out of lambdas or mismatch shape, just stop.
        _ ->
            subst


applySubst : Substitution -> Can.Type -> Mono.MonoType
applySubst subst canType =
    case canType of
        Can.TVar name ->
            case Dict.get identity name subst of
                Just monoType ->
                    monoType

                Nothing ->
                    Mono.MVar name (constraintFromName name)

        Can.TLambda from to ->
            Mono.MFunction [ applySubst subst from ] (applySubst subst to)

        Can.TType canonical name args ->
            let
                monoArgs =
                    List.map (applySubst subst) args

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
                        -- Custom type from elm/core
                        Mono.MCustom canonical name monoArgs

            else
                -- Custom type
                Mono.MCustom canonical name monoArgs

        Can.TRecord fields _ ->
            let
                monoFields =
                    Dict.map (\_ (Can.FieldType _ t) -> applySubst subst t) fields

                layout =
                    Mono.computeRecordLayout monoFields
            in
            Mono.MRecord layout

        Can.TTuple a b rest ->
            let
                monoTypes =
                    List.map (applySubst subst) (a :: b :: rest)

                layout =
                    Mono.computeTupleLayout monoTypes
            in
            Mono.MTuple layout

        Can.TUnit ->
            Mono.MUnit

        Can.TAlias _ _ _ (Can.Filled inner) ->
            applySubst subst inner

        Can.TAlias _ _ args (Can.Holey inner) ->
            let
                newSubst =
                    List.foldl
                        (\( name, t ) s ->
                            Dict.insert identity name (applySubst subst t) s
                        )
                        subst
                        args
            in
            applySubst newSubst inner


canTypeToMonoType : Substitution -> Can.Type -> Mono.MonoType
canTypeToMonoType =
    applySubst


constraintFromName : Name -> Mono.Constraint
constraintFromName name =
    if Name.isNumberType name then
        Mono.CNumber

    else if Name.isComparableType name then
        Mono.CComparable

    else if Name.isAppendableType name then
        Mono.CAppendable

    else if Name.isCompappendType name then
        Mono.CCompAppend

    else
        Mono.CAny



-- ============================================================================
-- LAYOUT HELPERS
-- ============================================================================


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


buildFuncType : List ( A.Located Name, Can.Type ) -> Can.Type -> Can.Type
buildFuncType args returnType =
    List.foldr
        (\( _, argType ) acc ->
            Can.TLambda argType acc
        )
        returnType
        args


buildCtorLayoutFromArity : Int -> Int -> Mono.MonoType -> Mono.CtorLayout
buildCtorLayoutFromArity tag arity monoType =
    let
        -- Extract field types from the function type
        -- For a constructor like `Foo : Int -> String -> Foo`, monoType is `MFunction [Int] (MFunction [String] (MCustom ... Foo))`
        fieldTypes =
            extractFieldTypes arity monoType

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

        unboxedCount =
            List.length (List.filter .isUnboxed fields)

        unboxedBitmap =
            if unboxedCount == 0 then
                0

            else
                (2 ^ unboxedCount) - 1
    in
    { name = ""
    , tag = tag
    , fields = fields
    , unboxedCount = unboxedCount
    , unboxedBitmap = unboxedBitmap
    }


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



-- ============================================================================
-- FREE VARIABLE ANALYSIS
-- ============================================================================


{-| Find free variables in a MonoExpr, given a set of bound variables.
Returns a list of (name, expr, isUnboxed) for captures.
-}
findFreeVars : EverySet String Name -> Mono.MonoExpr -> List ( Name, Mono.MonoExpr, Bool )
findFreeVars bound expr =
    case expr of
        Mono.MonoVarLocal name monoType ->
            if EverySet.member identity name bound then
                []

            else
                [ ( name, Mono.MonoVarLocal name monoType, Mono.canUnbox monoType ) ]

        Mono.MonoList _ exprs _ ->
            List.concatMap (findFreeVars bound) exprs

        Mono.MonoClosure closureInfo body _ ->
            -- Variables bound by closure params are not free
            let
                closureBound =
                    List.foldl (\( n, _ ) acc -> EverySet.insert identity n acc) bound closureInfo.params
            in
            findFreeVars closureBound body

        Mono.MonoCall _ func args _ ->
            findFreeVars bound func ++ List.concatMap (findFreeVars bound) args

        Mono.MonoTailCall _ args _ ->
            List.concatMap (\( _, e ) -> findFreeVars bound e) args

        Mono.MonoIf branches final _ ->
            List.concatMap (\( c, t ) -> findFreeVars bound c ++ findFreeVars bound t) branches
                ++ findFreeVars bound final

        Mono.MonoLet def body _ ->
            let
                ( defName, defExpr ) =
                    case def of
                        Mono.MonoDef n e ->
                            ( n, e )

                        Mono.MonoTailDef n e ->
                            ( n, e )

                newBound =
                    EverySet.insert identity defName bound
            in
            findFreeVars bound defExpr ++ findFreeVars newBound body

        Mono.MonoDestruct _ body _ ->
            findFreeVars bound body

        Mono.MonoCase _ _ _ jumps _ ->
            List.concatMap (\( _, e ) -> findFreeVars bound e) jumps

        Mono.MonoRecordCreate exprs _ _ ->
            List.concatMap (findFreeVars bound) exprs

        Mono.MonoRecordAccess record _ _ _ _ ->
            findFreeVars bound record

        Mono.MonoRecordUpdate record updates _ _ ->
            findFreeVars bound record ++ List.concatMap (\( _, e ) -> findFreeVars bound e) updates

        Mono.MonoTupleCreate _ exprs _ _ ->
            List.concatMap (findFreeVars bound) exprs

        _ ->
            -- Literals, globals, kernels, etc. have no free local vars
            []


{-| Remove duplicates from a list of captures based on name.
-}
dedupeCaptures : List ( Name, Mono.MonoExpr, Bool ) -> List ( Name, Mono.MonoExpr, Bool )
dedupeCaptures captures =
    let
        go seen acc remaining =
            case remaining of
                [] ->
                    List.reverse acc

                (( name, _, _ ) as cap) :: rest ->
                    if EverySet.member identity name seen then
                        go seen acc rest

                    else
                        go (EverySet.insert identity name seen) (cap :: acc) rest
    in
    go EverySet.empty [] captures



-- ============================================================================
-- DEPENDENCY COLLECTION
-- ============================================================================


collectDepsHelp : Mono.MonoExpr -> EverySet Int Int -> EverySet Int Int
collectDepsHelp expr deps =
    case expr of
        Mono.MonoVarGlobal _ specId _ ->
            EverySet.insert identity specId deps

        Mono.MonoList _ exprs _ ->
            List.foldl collectDepsHelp deps exprs

        Mono.MonoClosure _ body _ ->
            collectDepsHelp body deps

        Mono.MonoCall _ func args _ ->
            List.foldl collectDepsHelp (collectDepsHelp func deps) args

        Mono.MonoTailCall _ namedExprs _ ->
            List.foldl (\( _, e ) d -> collectDepsHelp e d) deps namedExprs

        Mono.MonoIf branches final _ ->
            let
                branchDeps =
                    List.foldl
                        (\( cond, body ) d ->
                            collectDepsHelp body (collectDepsHelp cond d)
                        )
                        deps
                        branches
            in
            collectDepsHelp final branchDeps

        Mono.MonoLet def body _ ->
            let
                defDeps =
                    case def of
                        Mono.MonoDef _ e ->
                            collectDepsHelp e deps

                        Mono.MonoTailDef _ e ->
                            collectDepsHelp e deps
            in
            collectDepsHelp body defDeps

        Mono.MonoDestruct _ body _ ->
            collectDepsHelp body deps

        Mono.MonoCase _ _ decider jumps _ ->
            let
                deciderDeps =
                    collectDeciderDeps decider deps
            in
            List.foldl (\( _, e ) d -> collectDepsHelp e d) deciderDeps jumps

        Mono.MonoRecordCreate exprs _ _ ->
            List.foldl collectDepsHelp deps exprs

        Mono.MonoRecordAccess record _ _ _ _ ->
            collectDepsHelp record deps

        Mono.MonoRecordUpdate record updates _ _ ->
            List.foldl (\( _, e ) d -> collectDepsHelp e d) (collectDepsHelp record deps) updates

        Mono.MonoTupleCreate _ exprs _ _ ->
            List.foldl collectDepsHelp deps exprs

        _ ->
            deps


collectDeciderDeps : Mono.Decider Mono.MonoChoice -> EverySet Int Int -> EverySet Int Int
collectDeciderDeps decider deps =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    collectDepsHelp expr deps

                Mono.Jump ->
                    deps

        Mono.Chain success failure ->
            collectDeciderDeps failure (collectDeciderDeps success deps)

        Mono.FanOut edges fallback ->
            let
                edgeDeps =
                    List.foldl (\( _, d ) acc -> collectDeciderDeps d acc) deps edges
            in
            collectDeciderDeps fallback edgeDeps



-- ============================================================================
-- GLOBAL CONVERSIONS
-- ============================================================================


toptGlobalToMono : TOpt.Global -> Mono.Global
toptGlobalToMono (TOpt.Global canonical name) =
    Mono.Global canonical name


monoGlobalToTOpt : Mono.Global -> TOpt.Global
monoGlobalToTOpt (Mono.Global canonical name) =
    TOpt.Global canonical name
