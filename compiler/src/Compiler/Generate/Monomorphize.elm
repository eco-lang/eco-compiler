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

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Index as Index
import Compiler.Data.Name exposing (Name)
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
    }


type WorkItem
    = SpecializeGlobal Mono.Global Mono.MonoType (Maybe Mono.LambdaId)


initState : IO.Canonical -> MonoState
initState currentModule =
    { worklist = []
    , nodes = Dict.empty
    , inProgress = EverySet.empty
    , registry = Mono.emptyRegistry
    , lambdaCounter = 0
    , currentModule = currentModule
    }



-- ============================================================================
-- MAIN ENTRY POINT
-- ============================================================================


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
                    initState currentModule

                stateWithMain =
                    { initialState
                        | worklist = [ SpecializeGlobal (toptGlobalToMono mainGlobal) monoType Nothing ]
                    }

                finalState =
                    processWorklist nodes stateWithMain

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
                    , main = mainSpecId
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


processWorklist : Dict (List String) TOpt.Global TOpt.Node -> MonoState -> MonoState
processWorklist toptNodes state =
    case state.worklist of
        [] ->
            state

        (SpecializeGlobal global monoType maybeLambda) :: rest ->
            let
                specKey =
                    Mono.SpecKey global monoType maybeLambda

                comparableKey =
                    Mono.toComparableSpecKey specKey
            in
            case Dict.get identity comparableKey state.registry.mapping of
                Just _ ->
                    -- Already specialized or in progress, skip
                    processWorklist toptNodes { state | worklist = rest }

                Nothing ->
                    -- Allocate new SpecId
                    let
                        ( specId, newRegistry ) =
                            Mono.getOrCreateSpecId global monoType maybeLambda state.registry

                        stateWithId =
                            { state
                                | registry = newRegistry
                                , inProgress = EverySet.insert identity specId state.inProgress
                                , worklist = rest
                            }

                        toptGlobal =
                            monoGlobalToTOpt global
                    in
                    case Dict.get TOpt.toComparableGlobal toptGlobal toptNodes of
                        Nothing ->
                            -- External/kernel function
                            let
                                newState =
                                    { stateWithId
                                        | nodes = Dict.insert identity specId (Mono.MonoExtern monoType) stateWithId.nodes
                                        , inProgress = EverySet.remove identity specId stateWithId.inProgress
                                    }
                            in
                            processWorklist toptNodes newState

                        Just toptNode ->
                            -- Specialize the node
                            let
                                ( monoNode, stateAfterSpec ) =
                                    specializeNode toptNode monoType maybeLambda stateWithId

                                newState =
                                    { stateAfterSpec
                                        | nodes = Dict.insert identity specId monoNode stateAfterSpec.nodes
                                        , inProgress = EverySet.remove identity specId stateAfterSpec.inProgress
                                    }
                            in
                            processWorklist toptNodes newState



-- ============================================================================
-- NODE SPECIALIZATION
-- ============================================================================


specializeNode : TOpt.Node -> Mono.MonoType -> Maybe Mono.LambdaId -> MonoState -> ( Mono.MonoNode, MonoState )
specializeNode node monoType maybeLambda state =
    case node of
        TOpt.Define expr _ canType ->
            let
                subst =
                    unify canType monoType

                ( monoExpr, stateAfter ) =
                    specializeExpr expr subst state

                depIds =
                    collectDependencies monoExpr
            in
            ( Mono.MonoDefine monoExpr depIds monoType, stateAfter )

        TOpt.TrackedDefine _ expr _ canType ->
            let
                subst =
                    unify canType monoType

                ( monoExpr, stateAfter ) =
                    specializeExpr expr subst state

                depIds =
                    collectDependencies monoExpr
            in
            ( Mono.MonoDefine monoExpr depIds monoType, stateAfter )

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

                depIds =
                    collectDependencies monoBody

                monoReturnType =
                    applySubst subst returnType
            in
            ( Mono.MonoTailFunc monoArgs monoBody depIds monoReturnType, stateAfter )

        TOpt.Ctor _ _ _ ->
            let
                layout =
                    buildCtorLayoutFromType monoType
            in
            ( Mono.MonoCtor layout monoType, state )

        TOpt.Enum index _ ->
            let
                tag =
                    Index.toMachine index
            in
            ( Mono.MonoEnum tag monoType, state )

        TOpt.Box _ ->
            ( Mono.MonoExtern monoType, state )

        TOpt.Link linkedGlobal ->
            -- Follow the link
            let
                monoGlobal =
                    toptGlobalToMono linkedGlobal

                workItem =
                    SpecializeGlobal monoGlobal monoType maybeLambda
            in
            ( Mono.MonoExtern monoType, { state | worklist = workItem :: state.worklist } )

        TOpt.Cycle _ _ _ _ ->
            -- Handle cycles - for now treat as extern
            ( Mono.MonoExtern monoType, state )

        TOpt.Manager _ ->
            ( Mono.MonoExtern monoType, state )

        TOpt.Kernel _ _ ->
            ( Mono.MonoExtern monoType, state )

        TOpt.PortIncoming expr _ canType ->
            let
                subst =
                    unify canType monoType

                ( monoExpr, stateAfter ) =
                    specializeExpr expr subst state

                depIds =
                    collectDependencies monoExpr
            in
            ( Mono.MonoPortIncoming monoExpr depIds monoType, stateAfter )

        TOpt.PortOutgoing expr _ canType ->
            let
                subst =
                    unify canType monoType

                ( monoExpr, stateAfter ) =
                    specializeExpr expr subst state

                depIds =
                    collectDependencies monoExpr
            in
            ( Mono.MonoPortOutgoing monoExpr depIds monoType, stateAfter )



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
                    Mono.AnonymousLambda state.currentModule state.lambdaCounter []

                stateWithLambda =
                    { state | lambdaCounter = state.lambdaCounter + 1 }

                ( monoBody, stateAfter ) =
                    specializeExpr body subst stateWithLambda

                closureInfo =
                    { lambdaId = lambdaId
                    , captures = []
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
                    Mono.AnonymousLambda state.currentModule state.lambdaCounter []

                stateWithLambda =
                    { state | lambdaCounter = state.lambdaCounter + 1 }

                ( monoBody, stateAfter ) =
                    specializeExpr body subst stateWithLambda

                closureInfo =
                    { lambdaId = lambdaId
                    , captures = []
                    , params = monoParams
                    }
            in
            ( Mono.MonoClosure closureInfo monoBody monoType, stateAfter )

        TOpt.Call region func args canType ->
            let
                monoType =
                    applySubst subst canType

                ( monoFunc, state1 ) =
                    specializeExpr func subst state

                ( monoArgs, state2 ) =
                    specializeExprs args subst state1

                -- Check for lambda specialization opportunity
                ( finalFunc, state3 ) =
                    maybeSpecializeForLambda monoFunc monoArgs state2
            in
            ( Mono.MonoCall region finalFunc monoArgs monoType, state3 )

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
        TOpt.Def region name expr canType ->
            let
                monoType =
                    applySubst subst canType

                ( monoExpr, stateAfter ) =
                    specializeExpr expr subst state
            in
            ( Mono.MonoDef region name monoExpr monoType, stateAfter )

        TOpt.TailDef region name args expr canType ->
            let
                monoType =
                    applySubst subst canType

                monoArgs =
                    List.map (\( locName, t ) -> ( A.toValue locName, applySubst subst t )) args

                ( monoExpr, stateAfter ) =
                    specializeExpr expr subst state
            in
            ( Mono.MonoTailDef region name monoArgs monoExpr monoType, stateAfter )


specializeDestructor : TOpt.Destructor -> Substitution -> Mono.MonoDestructor
specializeDestructor (TOpt.Destructor name path canType) subst =
    let
        monoType =
            applySubst subst canType

        monoPath =
            specializePath path
    in
    Mono.MonoDestructor name monoPath monoType


specializePath : TOpt.Path -> Mono.MonoPath
specializePath path =
    case path of
        TOpt.Index index subPath ->
            Mono.MonoIndex (Index.toMachine index) (specializePath subPath)

        TOpt.ArrayIndex idx subPath ->
            -- Treat array index as regular index for now
            Mono.MonoIndex idx (specializePath subPath)

        TOpt.Field name subPath ->
            -- Field access needs index lookup at runtime
            Mono.MonoField name 0 (specializePath subPath)

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

        TOpt.Chain tests success failure ->
            let
                ( monoSuccess, state1 ) =
                    specializeDecider success subst state

                ( monoFailure, state2 ) =
                    specializeDecider failure subst state1
            in
            ( Mono.Chain tests monoSuccess monoFailure, state2 )

        TOpt.FanOut path edges fallback ->
            let
                ( monoEdges, state1 ) =
                    specializeEdges edges subst state

                ( monoFallback, state2 ) =
                    specializeDecider fallback subst state1
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

        TOpt.Jump idx ->
            ( Mono.Jump idx, state )


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

        ( Can.TType _ _ args, Mono.MCustom _ _ monoArgs _ ) ->
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


applySubst : Substitution -> Can.Type -> Mono.MonoType
applySubst subst canType =
    case canType of
        Can.TVar name ->
            case Dict.get identity name subst of
                Just monoType ->
                    monoType

                Nothing ->
                    -- Unresolved type variable, default to Unit
                    Mono.MUnit

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
                        let
                            layout =
                                Mono.computeCustomLayout []
                        in
                        Mono.MCustom canonical name monoArgs layout

            else
                -- Custom type
                let
                    layout =
                        Mono.computeCustomLayout []
                in
                Mono.MCustom canonical name monoArgs layout

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


buildCtorLayoutFromType : Mono.MonoType -> Mono.CtorLayout
buildCtorLayoutFromType monoType =
    case monoType of
        Mono.MCustom _ _ _ layout ->
            case layout.constructors of
                ctor :: _ ->
                    ctor

                [] ->
                    { name = ""
                    , tag = 0
                    , fields = []
                    , unboxedCount = 0
                    , unboxedBitmap = 0
                    }

        _ ->
            { name = ""
            , tag = 0
            , fields = []
            , unboxedCount = 0
            , unboxedBitmap = 0
            }



-- ============================================================================
-- DEPENDENCY COLLECTION
-- ============================================================================


collectDependencies : Mono.MonoExpr -> EverySet Int Int
collectDependencies expr =
    collectDepsHelp expr EverySet.empty


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
                        Mono.MonoDef _ _ e _ ->
                            collectDepsHelp e deps

                        Mono.MonoTailDef _ _ _ e _ ->
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

        Mono.MonoTupleAccess tuple _ _ _ ->
            collectDepsHelp tuple deps

        Mono.MonoCustomCreate _ _ exprs _ _ ->
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

                Mono.Jump _ ->
                    deps

        Mono.Chain _ success failure ->
            collectDeciderDeps failure (collectDeciderDeps success deps)

        Mono.FanOut _ edges fallback ->
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
