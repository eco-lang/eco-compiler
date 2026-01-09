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
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Optimize.Typed.DecisionTree as DT
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import System.TypeCheck.IO as IO



-- ========== STATE ==========


{-| State maintained during monomorphization, tracking work to be done and completed specializations.
-}
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


{-| Work item representing a function specialization to be processed.
-}
type WorkItem
    = SpecializeGlobal Mono.Global Mono.MonoType (Maybe Mono.LambdaId)


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
monomorphize : Name -> TOpt.GlobalGraph -> Result String Mono.MonoGraph
monomorphize entryPointName (TOpt.GlobalGraph nodes _ _) =
    case findEntryPoint entryPointName nodes of
        Nothing ->
            Err ("No " ++ entryPointName ++ " function found")

        Just ( mainGlobal, mainType ) ->
            monomorphizeFromEntry mainGlobal mainType nodes


{-| Perform monomorphization from a given entry point.
-}
monomorphizeFromEntry : TOpt.Global -> Can.Type -> Dict (List String) TOpt.Global TOpt.Node -> Result String Mono.MonoGraph
monomorphizeFromEntry mainGlobal mainType nodes =
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
            initState currentModule nodes

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
            in
            Ok
                (Mono.MonoGraph
                    { nodes = finalState.nodes
                    , main = mainInfo
                    , registry = finalState.registry
                    }
                )



-- ========== INITIALIZATION ==========


{-| Initialize the monomorphization state with empty worklist and registry.
-}
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
                    state2 =
                        { state1
                            | inProgress = EverySet.insert identity specId state1.inProgress
                            , currentGlobal = Just global
                        }

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
                            ctorName =
                                case global of
                                    Mono.Global _ name ->
                                        name

                            ( monoNode, stateAfter ) =
                                specializeNode ctorName toptNode monoType state2

                            newState =
                                { stateAfter
                                    | nodes = Dict.insert identity specId monoNode stateAfter.nodes
                                    , inProgress = EverySet.remove identity specId stateAfter.inProgress
                                    , currentGlobal = Nothing
                                }
                        in
                        processWorklist newState



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
                    unify canType requestedMonoType

                ( monoExpr0, state1 ) =
                    specializeExpr expr subst state

                ( monoExpr, state2 ) =
                    ensureCallableTopLevel monoExpr0 requestedMonoType state1
            in
            ( Mono.MonoDefine monoExpr requestedMonoType, state2 )

        TOpt.TrackedDefine _ expr _ canType ->
            let
                subst =
                    unify canType requestedMonoType

                ( monoExpr0, state1 ) =
                    specializeExpr expr subst state

                ( monoExpr, state2 ) =
                    ensureCallableTopLevel monoExpr0 requestedMonoType state1
            in
            ( Mono.MonoDefine monoExpr requestedMonoType, state2 )

        TOpt.DefineTailFunc _ args body _ returnType ->
            let
                funcType =
                    buildFuncType args returnType

                subst =
                    unify funcType requestedMonoType

                monoArgs =
                    List.map (specializeArg subst) args

                ( monoBody, state1 ) =
                    specializeExpr body subst state

                monoReturnType =
                    applySubst subst returnType
            in
            ( Mono.MonoTailFunc monoArgs monoBody monoReturnType, state1 )

        TOpt.Ctor index arity canType ->
            let
                subst =
                    unify canType requestedMonoType

                ctorMonoType =
                    applySubst subst canType

                tag =
                    Index.toMachine index

                layout =
                    buildCtorLayoutFromArity ctorName tag arity ctorMonoType

                ctorResultType =
                    extractCtorResultType arity ctorMonoType
            in
            ( Mono.MonoCtor layout ctorResultType, state )

        TOpt.Enum index canType ->
            let
                monoType =
                    applySubst Dict.empty canType

                tag =
                    Index.toMachine index
            in
            ( Mono.MonoEnum tag monoType, state )

        TOpt.Box canType ->
            let
                monoType =
                    applySubst Dict.empty canType
            in
            ( Mono.MonoExtern monoType, state )

        TOpt.Link linkedGlobal ->
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

        TOpt.Cycle names values functions _ ->
            specializeCycle names values functions requestedMonoType state

        TOpt.Manager _ ->
            ( Mono.MonoExtern requestedMonoType, state )

        TOpt.Kernel _ _ ->
            ( Mono.MonoExtern requestedMonoType, state )

        TOpt.PortIncoming expr _ canType ->
            let
                subst =
                    unify canType requestedMonoType

                ( monoExpr0, state1 ) =
                    specializeExpr expr subst state

                ( monoExpr, state2 ) =
                    ensureCallableTopLevel monoExpr0 requestedMonoType state1
            in
            ( Mono.MonoPortIncoming monoExpr requestedMonoType, state2 )

        TOpt.PortOutgoing expr _ canType ->
            let
                subst =
                    unify canType requestedMonoType

                ( monoExpr0, state1 ) =
                    specializeExpr expr subst state

                ( monoExpr, state2 ) =
                    ensureCallableTopLevel monoExpr0 requestedMonoType state1
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
            -- Should not happen; conservative fallback
            ( Mono.MonoExtern requestedMonoType, state )

        ( False, Just (Mono.Global requestedCanonical requestedName) ) ->
            specializeFunctionCycle
                requestedCanonical
                requestedName
                valueDefs
                funcDefs
                requestedMonoType
                state


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
                    unify canType requestedMonoType

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


{-| NOTE:
We still do not promote the 'valueDefs' of a function cycle to separate
top-level MonoNodes, because we do not have explicit canonical types
for them here. They are assumed to be empty in function cycles in the
current TypedOptimized representation.

If that assumption ever breaks, this is the place to extend the API
to also specialize and register values as separate nodes.

For now, we keep valueDefs ignored in function cycles, but we no
longer "lose" function members (each function in the cycle gets its
own MonoTailFunc/MonoDefine node).

-}
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
            applySubst sharedSubst canType

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
                    applySubst subst canType

                ( monoExpr0, state1 ) =
                    specializeExpr expr subst state

                ( monoExpr, state2 ) =
                    ensureCallableTopLevel monoExpr0 monoType state1
            in
            ( Mono.MonoDefine monoExpr monoType, state2 )

        TOpt.TailDef _ _ args body returnType ->
            let
                monoArgs =
                    List.map (specializeArg subst) args

                ( monoBody, state1 ) =
                    specializeExpr body subst state

                monoReturnType =
                    applySubst subst returnType
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
                monoType0 =
                    applySubst subst canType

                -- If the type is an unresolved type variable (MVar), look up the actual
                -- type from the global's definition. This happens when the reference
                -- has a fresh type variable that wasn't in our substitution (e.g., when
                -- Html.text's body is just a reference to VirtualDom.text).
                monoType =
                    case monoType0 of
                        Mono.MVar _ _ ->
                            case Dict.get TOpt.toComparableGlobal global state.toptNodes of
                                Just (TOpt.Define _ _ defCanType) ->
                                    applySubst subst defCanType

                                Just (TOpt.TrackedDefine _ _ _ defCanType) ->
                                    applySubst subst defCanType

                                Just (TOpt.DefineTailFunc _ args _ _ returnType) ->
                                    applySubst subst (buildFuncType args returnType)

                                _ ->
                                    -- For Link, Kernel, etc. - keep the original type
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
                monoType =
                    applySubst subst canType

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
                    applySubst subst canType

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
                    applySubst subst canType

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
                monoType =
                    applySubst subst canType
            in
            ( Mono.MonoVarKernel region "Debug" name monoType, state )

        TOpt.VarKernel region home name canType ->
            let
                monoType =
                    if isAlwaysPolymorphicKernel home name then
                        -- Preserve type variables so they map to !eco.value
                        applySubst Dict.empty canType

                    else
                        -- Fully specialize the function type
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

                paramPairs =
                    List.map (\( name, t ) -> ( name, t )) params

                monoParams =
                    List.map (\( name, t ) -> ( name, applySubst subst t )) paramPairs

                lambdaId =
                    Mono.AnonymousLambda state.currentModule state.lambdaCounter

                stateWithLambda =
                    { state | lambdaCounter = state.lambdaCounter + 1 }

                ( monoBody, stateAfter ) =
                    specializeExpr body subst stateWithLambda

                captures =
                    computeClosureCaptures monoParams monoBody

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

                paramPairs =
                    List.map (\( locName, t ) -> ( A.toValue locName, t )) params

                monoParams =
                    List.map (\( name, t ) -> ( name, applySubst subst t )) paramPairs

                lambdaId =
                    Mono.AnonymousLambda state.currentModule state.lambdaCounter

                stateWithLambda =
                    { state | lambdaCounter = state.lambdaCounter + 1 }

                ( monoBody, stateAfter ) =
                    specializeExpr body subst stateWithLambda

                captures =
                    computeClosureCaptures monoParams monoBody

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
            in
            case func of
                -- Polymorphic global function call
                TOpt.VarGlobal funcRegion global funcCanType ->
                    let
                        argTypes =
                            List.map Mono.typeOf monoArgs

                        callSubst =
                            unifyFuncCall funcCanType argTypes canType subst

                        resultMonoType =
                            applySubst callSubst canType

                        funcMonoType =
                            applySubst callSubst funcCanType

                        monoGlobal =
                            toptGlobalToMono global

                        ( specId, newRegistry ) =
                            Mono.getOrCreateSpecId monoGlobal funcMonoType Nothing state1.registry

                        newState =
                            { state1
                                | registry = newRegistry
                                , worklist = SpecializeGlobal monoGlobal funcMonoType Nothing :: state1.worklist
                            }

                        monoFunc =
                            Mono.MonoVarGlobal funcRegion specId funcMonoType
                    in
                    ( Mono.MonoCall region monoFunc monoArgs resultMonoType, newState )

                -- Kernel function call
                TOpt.VarKernel funcRegion home name funcCanType ->
                    let
                        argTypes =
                            List.map Mono.typeOf monoArgs

                        callSubst =
                            unifyFuncCall funcCanType argTypes canType subst

                        resultMonoType =
                            applySubst callSubst canType

                        funcMonoType =
                            if isAlwaysPolymorphicKernel home name then
                                -- Preserve type variables in the function type so that
                                -- its ABI is all !eco.value
                                applySubst Dict.empty funcCanType

                            else
                                -- Fully specialize the function type
                                applySubst callSubst funcCanType

                        monoFunc =
                            Mono.MonoVarKernel funcRegion home name funcMonoType
                    in
                    ( Mono.MonoCall region monoFunc monoArgs resultMonoType, state1 )

                -- Debug function call (Debug.log, Debug.todo, etc.)
                -- Keep the original polymorphic type for the kernel function signature
                -- so type variables map to !eco.value at runtime (boxed values).
                TOpt.VarDebug funcRegion name _ _ funcCanType ->
                    let
                        argTypes =
                            List.map Mono.typeOf monoArgs

                        callSubst =
                            unifyFuncCall funcCanType argTypes canType subst

                        resultMonoType =
                            applySubst callSubst canType

                        -- Use empty substitution to keep type variables as MVar
                        -- This ensures polymorphic kernel functions use !eco.value
                        funcMonoType =
                            applySubst Dict.empty funcCanType

                        monoFunc =
                            Mono.MonoVarKernel funcRegion "Debug" name funcMonoType
                    in
                    ( Mono.MonoCall region monoFunc monoArgs resultMonoType, state1 )

                -- Fallback: general function expression
                _ ->
                    let
                        ( monoFunc, state2 ) =
                            specializeExpr func subst state1

                        resultMonoType =
                            applySubst subst canType
                    in
                    ( Mono.MonoCall region monoFunc monoArgs resultMonoType, state2 )

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
    List.foldr
        (\( cond, body ) ( acc, st ) ->
            let
                ( mCond, st1 ) =
                    specializeExpr cond subst st

                ( mBody, st2 ) =
                    specializeExpr body subst st1
            in
            ( ( mCond, mBody ) :: acc, st2 )
        )
        ( [], state )
        branches



-- ========== LAMBDA AND CLOSURE HANDLING ==========


{-| Ensure that a top-level expression is directly callable by wrapping it in a closure if necessary.
-}
ensureCallableTopLevel : Mono.MonoExpr -> Mono.MonoType -> MonoState -> ( Mono.MonoExpr, MonoState )
ensureCallableTopLevel expr monoType state =
    case monoType of
        Mono.MFunction _ _ ->
            let
                ( argTypes, retType ) =
                    flattenFunctionType monoType
            in
            case expr of
                Mono.MonoClosure closureInfo _ _ ->
                    if List.length closureInfo.params >= List.length argTypes then
                        ( expr, state )

                    else
                        -- Under-parameterized closure: wrap it in an alias closure
                        makeAliasClosureOverExpr expr argTypes retType monoType state

                Mono.MonoVarGlobal region specId _ ->
                    makeAliasClosure
                        (Mono.MonoVarGlobal region specId monoType)
                        region
                        argTypes
                        retType
                        monoType
                        state

                Mono.MonoVarKernel region home name _ ->
                    makeAliasClosure
                        (Mono.MonoVarKernel region home name monoType)
                        region
                        argTypes
                        retType
                        monoType
                        state

                _ ->
                    makeGeneralClosure expr argTypes retType monoType state

        _ ->
            ( expr, state )


{-| Flatten a curried function type into a list of argument types and a final return type.
-}
flattenFunctionType : Mono.MonoType -> ( List Mono.MonoType, Mono.MonoType )
flattenFunctionType monoType =
    case monoType of
        Mono.MFunction args ret ->
            let
                ( moreArgs, finalRet ) =
                    flattenFunctionType ret
            in
            ( args ++ moreArgs, finalRet )

        _ ->
            ( [], monoType )


makeAliasClosure :
    Mono.MonoExpr
    -> A.Region
    -> List Mono.MonoType
    -> Mono.MonoType
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoExpr, MonoState )
makeAliasClosure calleeExpr region argTypes retType funcType state =
    let
        params =
            freshParams argTypes

        paramExprs =
            List.map (\( name, ty ) -> Mono.MonoVarLocal name ty) params

        lambdaId =
            Mono.AnonymousLambda state.currentModule state.lambdaCounter

        stateWithLambda =
            { state | lambdaCounter = state.lambdaCounter + 1 }

        callExpr =
            Mono.MonoCall region calleeExpr paramExprs retType

        closureInfo =
            { lambdaId = lambdaId
            , captures = []
            , params = params
            }

        closureExpr =
            Mono.MonoClosure closureInfo callExpr funcType
    in
    ( closureExpr, stateWithLambda )


makeGeneralClosure :
    Mono.MonoExpr
    -> List Mono.MonoType
    -> Mono.MonoType
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoExpr, MonoState )
makeGeneralClosure expr argTypes retType funcType state =
    let
        region =
            extractRegion expr

        params =
            freshParams argTypes

        paramExprs =
            List.map (\( name, ty ) -> Mono.MonoVarLocal name ty) params

        lambdaId =
            Mono.AnonymousLambda state.currentModule state.lambdaCounter

        stateWithLambda =
            { state | lambdaCounter = state.lambdaCounter + 1 }

        callExpr =
            Mono.MonoCall region expr paramExprs retType

        closureInfo =
            { lambdaId = lambdaId
            , captures = []
            , params = params
            }

        closureExpr =
            Mono.MonoClosure closureInfo callExpr funcType
    in
    ( closureExpr, stateWithLambda )


makeAliasClosureOverExpr :
    Mono.MonoExpr
    -> List Mono.MonoType
    -> Mono.MonoType
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoExpr, MonoState )
makeAliasClosureOverExpr expr argTypes retType funcType state =
    -- For now, treat it like a general closure around the expression.
    -- If you later want to reuse existing captures of an inner closure,
    -- you can extend this to preserve them.
    makeGeneralClosure expr argTypes retType funcType state


freshParams : List Mono.MonoType -> List ( Name, Mono.MonoType )
freshParams argTypes =
    List.indexedMap
        (\i ty -> ( "arg" ++ String.fromInt i, ty ))
        argTypes


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

        Mono.MonoRecordAccess record _ _ _ _ ->
            extractRegion record

        Mono.MonoRecordUpdate record _ _ _ ->
            extractRegion record

        Mono.MonoTupleCreate region _ _ _ ->
            region

        Mono.MonoUnit ->
            A.zero

        Mono.MonoAccessor region _ _ ->
            region



-- ========== CLOSURE CAPTURE ANALYSIS ==========


{-| Compute the free variables that need to be captured by a closure.
-}
computeClosureCaptures :
    List ( Name, Mono.MonoType )
    -> Mono.MonoExpr
    -> List ( Name, Mono.MonoExpr, Bool )
computeClosureCaptures params body =
    let
        boundInitial : EverySet String Name
        boundInitial =
            List.foldl
                (\( name, _ ) acc -> EverySet.insert identity name acc)
                EverySet.empty
                params

        freeNames : List Name
        freeNames =
            findFreeLocals boundInitial body
                |> dedupeNames

        captureFor name =
            let
                -- We do not track an environment here; in practice we only
                -- capture by name and type from the VarLocal uses.
                -- For now, use a placeholder MUnit when the type is unknown.
                placeholderType =
                    Mono.MUnit
            in
            ( name, Mono.MonoVarLocal name placeholderType, False )
    in
    List.map captureFor freeNames


{-| Find free local variable names in an expression.
-}
findFreeLocals :
    EverySet String Name
    -> Mono.MonoExpr
    -> List Name
findFreeLocals bound expr =
    case expr of
        Mono.MonoVarLocal name _ ->
            if EverySet.member identity name bound then
                []

            else
                [ name ]

        Mono.MonoClosure _ _ _ ->
            -- Nested closures compute their own captures; do not descend.
            []

        -- Alternatively, you could choose to recurse into body
        -- with closure params added to bound if you want combined info.
        Mono.MonoLet def body _ ->
            let
                ( defName, defExpr ) =
                    case def of
                        Mono.MonoDef n e ->
                            ( n, e )

                        Mono.MonoTailDef n e ->
                            ( n, e )

                freeInDef =
                    findFreeLocals bound defExpr

                newBound =
                    EverySet.insert identity defName bound

                freeInBody =
                    findFreeLocals newBound body
            in
            freeInDef ++ freeInBody

        Mono.MonoIf branches final _ ->
            let
                freeBranches =
                    List.concatMap
                        (\( cond, thenExpr ) ->
                            findFreeLocals bound cond
                                ++ findFreeLocals bound thenExpr
                        )
                        branches

                freeFinal =
                    findFreeLocals bound final
            in
            freeBranches ++ freeFinal

        Mono.MonoCase _ _ decider jumps _ ->
            let
                freeDecider =
                    collectDeciderFreeLocals bound decider

                freeJumps =
                    List.concatMap (\( _, e ) -> findFreeLocals bound e) jumps
            in
            freeDecider ++ freeJumps

        Mono.MonoList _ exprs _ ->
            List.concatMap (findFreeLocals bound) exprs

        Mono.MonoCall _ func args _ ->
            findFreeLocals bound func
                ++ List.concatMap (findFreeLocals bound) args

        Mono.MonoTailCall _ namedExprs _ ->
            List.concatMap (\( _, e ) -> findFreeLocals bound e) namedExprs

        Mono.MonoRecordCreate exprs _ _ ->
            List.concatMap (findFreeLocals bound) exprs

        Mono.MonoRecordAccess record _ _ _ _ ->
            findFreeLocals bound record

        Mono.MonoRecordUpdate record updates _ _ ->
            findFreeLocals bound record
                ++ List.concatMap (\( _, e ) -> findFreeLocals bound e) updates

        Mono.MonoTupleCreate _ exprs _ _ ->
            List.concatMap (findFreeLocals bound) exprs

        _ ->
            []


collectDeciderFreeLocals :
    EverySet String Name
    -> Mono.Decider Mono.MonoChoice
    -> List Name
collectDeciderFreeLocals bound decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    findFreeLocals bound expr

                Mono.Jump _ ->
                    []

        Mono.Chain _ success failure ->
            collectDeciderFreeLocals bound success
                ++ collectDeciderFreeLocals bound failure

        Mono.FanOut _ edges fallback ->
            let
                freeEdges =
                    List.concatMap (\( _, d ) -> collectDeciderFreeLocals bound d) edges

                freeFallback =
                    collectDeciderFreeLocals bound fallback
            in
            freeEdges ++ freeFallback


dedupeNames : List Name -> List Name
dedupeNames names =
    let
        step name ( seen, acc ) =
            if EverySet.member identity name seen then
                ( seen, acc )

            else
                ( EverySet.insert identity name seen, name :: acc )
    in
    names
        |> List.foldl step ( EverySet.empty, [] )
        |> Tuple.second
        |> List.reverse



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

        TOpt.TailDef _ name _ expr _ ->
            let
                ( monoExpr, stateAfter ) =
                    specializeExpr expr subst state
            in
            ( Mono.MonoTailDef name monoExpr, stateAfter )


specializeDestructor : TOpt.Destructor -> Substitution -> Mono.MonoDestructor
specializeDestructor (TOpt.Destructor name path canType) subst =
    let
        monoPath =
            specializePath path

        monoType =
            applySubst subst canType
    in
    Mono.MonoDestructor name monoPath monoType


specializePath : TOpt.Path -> Mono.MonoPath
specializePath path =
    case path of
        TOpt.Index index hint subPath ->
            Mono.MonoIndex (Index.toMachine index) (hintToKind hint) (specializePath subPath)

        TOpt.ArrayIndex idx subPath ->
            -- Treat array index as regular index for now (large tuples)
            Mono.MonoIndex idx Mono.CustomContainer (specializePath subPath)

        TOpt.Field _ subPath ->
            -- Field access needs index lookup at runtime
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
            -- Default to CustomContainer for unknown hints
            Mono.CustomContainer


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
                ( monoSuccess, state1 ) =
                    specializeDecider success subst state

                ( monoFailure, state2 ) =
                    specializeDecider failure subst state1
            in
            ( Mono.Chain testChain monoSuccess monoFailure, state2 )

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

        TOpt.Jump index ->
            ( Mono.Jump index, state )


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



-- ====== LAMBDA SPECIALIZATION ======
-- ========== ETA-EXPANSION HELPERS ==========
-- ========== TYPE UNIFICATION AND SUBSTITUTION ==========


{-| Substitution mapping type variable names to their concrete monomorphic types.
-}
type alias Substitution =
    Dict String Name Mono.MonoType


{-| Unify a function call by matching argument types and result type.
-}
unifyFuncCall :
    Can.Type
    -> List Mono.MonoType
    -> Can.Type
    -> Substitution
    -> Substitution
unifyFuncCall funcCanType argMonoTypes resultCanType baseSubst =
    let
        subst1 =
            unifyArgsOnly funcCanType argMonoTypes baseSubst

        desiredResultMono =
            applySubst subst1 resultCanType

        desiredFuncMono =
            Mono.MFunction argMonoTypes desiredResultMono
    in
    unifyHelp funcCanType desiredFuncMono subst1


{-| Unify a canonical type with a monomorphic type to produce a substitution for type variables.
-}
unify : Can.Type -> Mono.MonoType -> Substitution
unify canType monoType =
    unifyHelp canType monoType Dict.empty


{-| Helper for unification that extends an existing substitution.
-}
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


{-| Apply a type substitution to a canonical type to produce a monomorphic type.
-}
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

    else
        Mono.CEcoValue



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
The name parameter is used to populate CtorLayout.name for debug printing.
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

        -- Clamp to 32 bits: the runtime Custom.unboxed field is only 32 bits wide.
        -- Fields at index >= 32 are treated as boxed even if they could be unboxed.
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



-- ========== FREE VARIABLE ANALYSIS ==========
-- ========== DEPENDENCY COLLECTION ==========


{-| Collect all global dependencies referenced by an expression.
-}
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



-- ========== KERNEL POLYMORPHISM ==========


{-| Kernels whose C ABI must remain polymorphic (all boxed eco.value).

For these, we preserve type variables in the function type so that
monoTypeToMlir maps their parameters/results to !eco.value.

Note: Debug.\* kernels are handled via VarDebug special case in specializeExpr,
not listed here. Most other modules (VirtualDom, Json, etc.) don't need listing
because their heap types already map to !eco.value via monoTypeToMlir.

-}
isAlwaysPolymorphicKernel : String -> String -> Bool
isAlwaysPolymorphicKernel home name =
    case home of
        "Utils" ->
            -- Polymorphic over comparable/equatable/appendable types
            name
                == "compare"
                || name
                == "equal"
                || name
                == "append"
                || name
                == "lt"
                || name
                == "le"
                || name
                == "gt"
                || name
                == "ge"
                || name
                == "notEqual"

        "Basics" ->
            -- Fallback when `number` leaks through monomorphization
            name
                == "add"
                || name
                == "sub"
                || name
                == "mul"
                || name
                == "pow"

        _ ->
            False



-- ========== GLOBAL CONVERSIONS ==========


{-| Convert a typed optimized global reference to a monomorphized global reference.
-}
toptGlobalToMono : TOpt.Global -> Mono.Global
toptGlobalToMono (TOpt.Global canonical name) =
    Mono.Global canonical name


{-| Convert a monomorphized global reference to a typed optimized global reference.
-}
monoGlobalToTOpt : Mono.Global -> TOpt.Global
monoGlobalToTOpt (Mono.Global canonical name) =
    TOpt.Global canonical name
