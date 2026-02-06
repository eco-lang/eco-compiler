module Compiler.Monomorphize.Specialize exposing (specializeNode)

{-| Expression and node specialization for monomorphization.

This module handles converting typed optimized expressions and nodes
into monomorphized form by applying type substitutions.


# Specialization

@docs specializeNode

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.Monomorphize.Registry as Registry
import Compiler.Monomorphize.Segmentation as Seg
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.LocalOpt.Typed.DecisionTree as DT
import Compiler.Monomorphize.Analysis as Analysis
import Compiler.Monomorphize.Closure as Closure
import Compiler.Monomorphize.KernelAbi as KernelAbi
import Compiler.Monomorphize.State exposing (MonoState, Substitution, VarTypes, WorkItem(..))
import Compiler.Monomorphize.TypeSubst as TypeSubst
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



-- ========== LAMBDA PEELING ==========


{-| Peel nested Function/TrackedFunction expressions into a flat parameter list.

This helper recursively descends through nested lambda expressions, collecting
all parameters into a single list. It handles both Function and TrackedFunction
variants uniformly, converting TrackedFunction's Located names to plain names.

Returns (allParams, finalBody) where:

  - allParams: All parameters from the entire lambda chain, in order
  - finalBody: The first non-function expression encountered

-}
peelFunctionChain : TOpt.Expr -> ( List ( Name, Can.Type ), TOpt.Expr )
peelFunctionChain expr =
    case expr of
        TOpt.Function params body _ ->
            let
                ( moreParams, finalBody ) =
                    peelFunctionChain body
            in
            ( params ++ moreParams, finalBody )

        TOpt.TrackedFunction params body _ ->
            let
                -- Convert Located names to plain names
                plainParams =
                    List.map (\( locName, ty ) -> ( A.toValue locName, ty )) params

                ( moreParams, finalBody ) =
                    peelFunctionChain body
            in
            ( plainParams ++ moreParams, finalBody )

        _ ->
            ( [], expr )


{-| Drop n arguments from a nested MFunction chain, returning the remaining type.
For example, dropNArgsFromType 2 (MFunction [a] (MFunction [b] (MFunction [c] ret)))
returns MFunction [c] ret.
-}
dropNArgsFromType : Int -> Mono.MonoType -> Mono.MonoType
dropNArgsFromType n monoType =
    if n <= 0 then
        monoType

    else
        case monoType of
            Mono.MFunction args result ->
                let
                    argsLen =
                        List.length args
                in
                if n >= argsLen then
                    dropNArgsFromType (n - argsLen) result

                else
                    -- Partial consumption of this stage's args
                    Mono.MFunction (List.drop n args) result

            _ ->
                monoType


{-| Specialize a lambda expression (Function or TrackedFunction) using two-mode logic.

This implements the MONO\_016 invariant with stage-aware closure construction:

1.  **Fully Peelable (uncurried)**: Simple lambda chains like `\x -> \y -> \z -> body`
    are flattened into a single `MFunction [x,y,z] ret` closure.

2.  **Wrapper/Curried (staged)**: Lambdas separated by `let`/`case` like
    `\x -> let ... in \y -> body` preserve nested `MFunction [x] (MFunction [y] ret)`
    structure, with only the first stage params in this closure.

This is the core Option A transformation: nested lambdas become a single
uncurried closure. Partial application is represented only via PAPs downstream.

-}
specializeLambda :
    TOpt.Expr
    -> Can.Type
    -> Substitution
    -> MonoState
    -> ( Mono.MonoExpr, MonoState )
specializeLambda lambdaExpr canType subst state =
    let
        -- Stage-aware MonoType (nested MFunction chain, no flattening)
        monoType0 : Mono.MonoType
        monoType0 =
            TypeSubst.applySubst subst canType

        -- Total flattened args & final return (for fully-peelable lambdas)
        ( flatArgTypes, flatRetType ) =
            Seg.decomposeFunctionType monoType0

        totalArity : Int
        totalArity =
            List.length flatArgTypes

        -- Peel syntactic chain of lambdas (stops at let/case)
        ( allParams, finalBodyExpr ) =
            peelFunctionChain lambdaExpr

        paramCount : Int
        paramCount =
            List.length allParams
    in
    -- Guard: paramCount == 0 is a bug (caller invoked specializeLambda on non-lambda)
    if paramCount == 0 then
        let
            exprKind =
                case lambdaExpr of
                    TOpt.Function ps _ _ ->
                        "Function with " ++ String.fromInt (List.length ps) ++ " direct params"

                    TOpt.TrackedFunction ps _ _ ->
                        "TrackedFunction with " ++ String.fromInt (List.length ps) ++ " direct params"

                    _ ->
                        "Non-function expression"
        in
        Utils.Crash.crash
            ("specializeLambda: called with non-lambda or zero-arg lambda. "
                ++ exprKind
                ++ ", canType="
                ++ Debug.toString canType
                ++ ", monoType0="
                ++ Debug.toString monoType0
                ++ ", totalArity="
                ++ String.fromInt totalArity
            )
        -- Guard: totalArity == 0 means non-function type
        -- This is defensive and should not occur in well-typed Elm code, since specializeLambda
        -- is only called on Function/TrackedFunction nodes which always have function types.
        -- We handle it by rebuilding an MFunction from the params as a fallback.

    else if totalArity == 0 then
        let
            -- Derive param types from canonical params
            monoParams =
                List.map (\( name, paramCanType ) -> ( name, TypeSubst.applySubst subst paramCanType )) allParams

            returnType =
                TypeSubst.applySubst subst (TOpt.typeOf finalBodyExpr)

            effectiveMonoType =
                Mono.MFunction (List.map Tuple.second monoParams) returnType

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
                    (List.map2 Tuple.pair allParams monoParams)

            ( monoBody, stateAfter ) =
                specializeExpr finalBodyExpr augmentedSubst stateWithLambda

            captures =
                Closure.computeClosureCaptures monoParams monoBody

            closureInfo =
                { lambdaId = lambdaId
                , captures = captures
                , params = monoParams
                }
        in
        ( Mono.MonoClosure closureInfo monoBody effectiveMonoType, stateAfter )

    else
        -- Normal case: totalArity > 0 and paramCount > 0
        let
            -- Key decision: is this a simple lambda chain or a wrapper?
            isFullyPeelable : Bool
            isFullyPeelable =
                paramCount == totalArity

            -- Effective MonoType: uncurried for simple chains, staged for wrappers
            -- For wrappers, we build an MFunction with exactly paramCount args,
            -- and the return type is what's left after consuming those args from the type.
            effectiveMonoType : Mono.MonoType
            effectiveMonoType =
                if isFullyPeelable then
                    Mono.MFunction flatArgTypes flatRetType

                else
                    -- Wrapper: build MFunction with first paramCount args
                    let
                        wrapperArgs =
                            List.take paramCount flatArgTypes

                        wrapperReturnType =
                            dropNArgsFromType paramCount monoType0
                    in
                    Mono.MFunction wrapperArgs wrapperReturnType

            -- Effective param types for type derivation
            -- In the curried path (wrapper), we use the first paramCount types from the
            -- flattened type. This is necessary because:
            -- - The staged applySubst creates nested MFunction where each level has 1 arg
            -- - But Elm source can have multiple params per Function node (\x y -> body)
            -- - So we take the first paramCount flattened args to match the syntactic params
            effectiveParamTypes : List Mono.MonoType
            effectiveParamTypes =
                if isFullyPeelable then
                    flatArgTypes

                else
                -- Wrapper/curried case: take first paramCount types from flattened type
                -- Guard: paramCount must not exceed totalArity
                if
                    paramCount > totalArity
                then
                    Utils.Crash.crash
                        ("specializeLambda: paramCount ("
                            ++ String.fromInt paramCount
                            ++ ") > totalArity ("
                            ++ String.fromInt totalArity
                            ++ ") for lambda"
                        )

                else
                    List.take paramCount flatArgTypes

            deriveParamType : Int -> ( Name, Can.Type ) -> ( Name, Mono.MonoType )
            deriveParamType idx ( name, paramCanType ) =
                let
                    funcParamTypeAtIdx =
                        List.drop idx effectiveParamTypes |> List.head

                    substType =
                        TypeSubst.applySubst subst paramCanType

                    finalType =
                        case funcParamTypeAtIdx of
                            Just funcParamType ->
                                case paramCanType of
                                    Can.TVar _ ->
                                        funcParamType

                                    _ ->
                                        case substType of
                                            Mono.MVar _ _ ->
                                                funcParamType

                                            _ ->
                                                substType

                            Nothing ->
                                substType
                in
                ( name, finalType )

            monoParams : List ( Name, Mono.MonoType )
            monoParams =
                List.indexedMap deriveParamType allParams

            -- MONO_016 assertion: closure params must match stage arity
            _ =
                let
                    stageArityCheck =
                        Seg.stageParamTypes effectiveMonoType
                in
                if List.length monoParams /= List.length stageArityCheck then
                    Utils.Crash.crash
                        ("MONO_016 violation: closure has "
                            ++ String.fromInt (List.length monoParams)
                            ++ " params but effectiveMonoType has stage arity "
                            ++ String.fromInt (List.length stageArityCheck)
                        )

                else
                    ()

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
                    (List.map2 Tuple.pair allParams monoParams)

            ( monoBody, stateAfter ) =
                specializeExpr finalBodyExpr augmentedSubst stateWithLambda

            captures =
                Closure.computeClosureCaptures monoParams monoBody

            closureInfo =
                { lambdaId = lambdaId
                , captures = captures
                , params = monoParams
                }

            -- Reconcile function return type with the specialized body.
            -- This is where we propagate canonical case types (e.g. [2]) back
            -- into the enclosing function's return type.
            bodyType : Mono.MonoType
            bodyType =
                Mono.typeOf monoBody

            effectiveMonoTypeFixed : Mono.MonoType
            effectiveMonoTypeFixed =
                case effectiveMonoType of
                    Mono.MFunction argTypes _ ->
                        Mono.MFunction argTypes bodyType

                    _ ->
                        effectiveMonoType
        in
        ( Mono.MonoClosure closureInfo monoBody effectiveMonoTypeFixed, stateAfter )



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

                -- Use the expression's actual type for consistency (MONO_016)
                -- The closure inside monoExpr may have a different type than requestedMonoType
                -- (e.g., flattened MFunction vs nested MFunction)
                actualType =
                    Mono.typeOf monoExpr
            in
            ( Mono.MonoDefine monoExpr actualType, state2 )

        TOpt.TrackedDefine _ expr _ canType ->
            let
                subst =
                    TypeSubst.unify canType requestedMonoType

                ( monoExpr0, state1 ) =
                    specializeExpr expr subst state

                ( monoExpr, state2 ) =
                    Closure.ensureCallableTopLevel monoExpr0 requestedMonoType state1

                -- Use the expression's actual type for consistency (MONO_016)
                actualType =
                    Mono.typeOf monoExpr
            in
            ( Mono.MonoDefine monoExpr actualType, state2 )

        TOpt.Ctor index arity canType ->
            let
                subst =
                    TypeSubst.unify canType requestedMonoType

                ctorMonoType =
                    TypeSubst.applySubst subst canType

                tag =
                    Index.toMachine index

                shape =
                    buildCtorShapeFromArity ctorName tag arity ctorMonoType

                ctorResultType =
                    extractCtorResultType arity requestedMonoType
            in
            ( Mono.MonoCtor shape ctorResultType, state )

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
            Utils.Crash.crash "Specialize.specializeCycle: Accessor should not appear in cycles"


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
            List.foldl
                (specializeFunc requestedCanonical requestedName requestedMonoType sharedSubst)
                ( state.nodes, state )
                funcDefs

        requestedGlobal =
            Mono.Global requestedCanonical requestedName

        ( requestedSpecId, _ ) =
            Registry.getOrCreateSpecId requestedGlobal requestedMonoType Nothing stateAfter.registry
    in
    case Dict.get identity requestedSpecId newNodes of
        Just requestedNode ->
            ( requestedNode, { stateAfter | nodes = newNodes } )

        Nothing ->
            ( Mono.MonoExtern requestedMonoType, { stateAfter | nodes = newNodes } )


specializeFunc :
    IO.Canonical
    -> Name
    -> Mono.MonoType
    -> Substitution
    -> TOpt.Def
    -> ( Dict Int Int Mono.MonoNode, MonoState )
    -> ( Dict Int Int Mono.MonoNode, MonoState )
specializeFunc requestedCanonical requestedName requestedMonoType sharedSubst def ( accNodes, accState ) =
    let
        name =
            getDefName def

        globalFun =
            Mono.Global requestedCanonical name

        canType =
            getDefCanonicalType def

        monoTypeFromDef =
            TypeSubst.applySubst sharedSubst canType

        -- For the requested function in this cycle, use the exact MonoType
        -- from the worklist (requestedMonoType) as the specialization key.
        -- This ensures the SpecId matches what call sites expect.
        monoTypeForSpecId =
            if name == requestedName then
                requestedMonoType

            else
                monoTypeFromDef

        ( specId, newRegistry ) =
            Registry.getOrCreateSpecId globalFun monoTypeForSpecId Nothing accState.registry

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

                -- Use the actual type from the expression after ensureCallableTopLevel
                -- to ensure consistency between the node type and its contained closure type
                actualType =
                    Mono.typeOf monoExpr
            in
            ( Mono.MonoDefine monoExpr actualType, state2 )

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

                -- FIX: Use augmentedSubst (not subst) so the type reflects param constraints
                -- (e.g., number constraints resolved to MInt/MFloat).
                -- Note: `returnType` is misleadingly named - it's actually the FULL function
                -- type of the definition (e.g., Int -> Int -> Int becomes MFunction [MInt] (MFunction [MInt] MInt)).
                -- Context.extractNodeSignature expects this full function type and extracts
                -- the actual return type from it.
                monoFuncType =
                    TypeSubst.applySubst augmentedSubst returnType
            in
            ( Mono.MonoTailFunc monoArgs monoBody monoFuncType, state1 )



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
                    Registry.getOrCreateSpecId monoGlobal monoType Nothing state.registry

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
                    Registry.getOrCreateSpecId monoGlobal monoType Nothing state.registry

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
                    Registry.getOrCreateSpecId monoGlobal monoType Nothing state.registry

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
                    Registry.getOrCreateSpecId monoGlobal monoType Nothing state.registry

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
            specializeLambda (TOpt.Function params body canType) canType subst state

        TOpt.TrackedFunction params body canType ->
            specializeLambda (TOpt.TrackedFunction params body canType) canType subst state

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
                            Registry.getOrCreateSpecId monoGlobal funcMonoType Nothing state2.registry

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
                    specializeDestructor destructor subst state.varTypes state.globalTypeEnv

                (Mono.MonoDestructor destructorName _ destructorType) =
                    monoDestructor

                stateWithVar =
                    { state | varTypes = Dict.insert identity destructorName destructorType state.varTypes }

                ( monoBody, stateAfter ) =
                    specializeExpr body subst stateWithVar
            in
            ( Mono.MonoDestruct monoDestructor monoBody monoType, stateAfter )

        TOpt.Case label root decider jumps canType ->
            -- ABI normalization for case expressions has been moved to MonoGlobalOptimize.
            -- Here we simply specialize the branches and use the type from the substitution.
            let
                monoTypeFromCan =
                    TypeSubst.applySubst subst canType

                initialVarTypes =
                    state.varTypes

                ( monoDecider0, state1 ) =
                    specializeDecider decider subst state

                state1WithResetVarTypes =
                    { state1 | varTypes = initialVarTypes }

                ( monoJumps0, state2 ) =
                    specializeJumps jumps subst state1WithResetVarTypes
            in
            ( Mono.MonoCase label root monoDecider0 monoJumps0 monoTypeFromCan, state2 )

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
                    Registry.getOrCreateSpecId accessorGlobal monoType Nothing state.registry

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
            in
            ( Mono.MonoRecordAccess monoRecord fieldName monoType, stateAfter )

        TOpt.Update _ record updates canType ->
            let
                monoType =
                    TypeSubst.applySubst subst canType

                ( monoRecord, state1 ) =
                    specializeExpr record subst state

                ( monoUpdates, state2 ) =
                    specializeUpdates updates subst state1
            in
            ( Mono.MonoRecordUpdate monoRecord monoUpdates monoType, state2 )

        TOpt.Record fields canType ->
            let
                monoType =
                    TypeSubst.applySubst subst canType

                ( monoFields, stateAfter ) =
                    specializeRecordFields fields subst state
            in
            ( Mono.MonoRecordCreate monoFields monoType, stateAfter )

        TOpt.TrackedRecord _ fields canType ->
            let
                monoType =
                    TypeSubst.applySubst subst canType

                ( monoFields, stateAfter ) =
                    specializeTrackedRecordFields fields subst state
            in
            ( Mono.MonoRecordCreate monoFields monoType, stateAfter )

        TOpt.Unit _ ->
            ( Mono.MonoUnit, state )

        TOpt.Tuple region a b rest canType ->
            let
                monoType =
                    TypeSubst.applySubst subst canType

                ( monoA, state1 ) =
                    specializeExpr a subst state

                ( monoB, state2 ) =
                    specializeExpr b subst state1

                ( monoRest, state3 ) =
                    specializeExprs rest subst state2

                allExprs =
                    monoA :: monoB :: monoRest
            in
            ( Mono.MonoTupleCreate region allExprs monoType, state3 )

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
                Just (Mono.MFunction [ Mono.MRecord fields ] _) ->
                    -- The parameter type is a function from record to something.
                    -- Derive accessor's MonoType from the full record layout.
                    let
                        fieldType =
                            case Dict.get identity fieldName fields of
                                Just ft ->
                                    ft

                                Nothing ->
                                    Utils.Crash.crash ("Specialize.resolveProcessedArg: Field " ++ fieldName ++ " not found in record. This is a compiler bug.")

                        recordType =
                            Mono.MRecord fields

                        accessorMonoType =
                            Mono.MFunction [ recordType ] fieldType

                        accessorGlobal =
                            Mono.Accessor fieldName

                        ( specId, newRegistry ) =
                            Registry.getOrCreateSpecId accessorGlobal accessorMonoType Nothing state.registry

                        newState =
                            { state
                                | registry = newRegistry
                                , worklist = SpecializeGlobal accessorGlobal accessorMonoType Nothing :: state.worklist
                            }
                    in
                    ( Mono.MonoVarGlobal region specId accessorMonoType, newState )

                Just (Mono.MRecord fields) ->
                    -- The parameter type is directly a record (accessor applied to record).
                    -- This case handles when the accessor IS the function being called.
                    let
                        fieldType =
                            case Dict.get identity fieldName fields of
                                Just ft ->
                                    ft

                                Nothing ->
                                    Utils.Crash.crash ("Specialize.resolveProcessedArg: Field " ++ fieldName ++ " not found in record (direct). This is a compiler bug.")

                        recordType =
                            Mono.MRecord fields

                        accessorMonoType =
                            Mono.MFunction [ recordType ] fieldType

                        accessorGlobal =
                            Mono.Accessor fieldName

                        ( specId, newRegistry ) =
                            Registry.getOrCreateSpecId accessorGlobal accessorMonoType Nothing state.registry

                        newState =
                            { state
                                | registry = newRegistry
                                , worklist = SpecializeGlobal accessorGlobal accessorMonoType Nothing :: state.worklist
                            }
                    in
                    ( Mono.MonoVarGlobal region specId accessorMonoType, newState )

                _ ->
                    Utils.Crash.crash "Specialize.resolveProcessedArg: Accessor argument did not receive a record parameter type after monomorphization. This is a compiler bug."


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


specializeDestructor : TOpt.Destructor -> Substitution -> VarTypes -> TypeEnv.GlobalTypeEnv -> Mono.MonoDestructor
specializeDestructor (TOpt.Destructor name path canType) subst varTypes globalTypeEnv =
    let
        monoPath =
            specializePath path subst varTypes globalTypeEnv

        monoType =
            TypeSubst.applySubst subst canType
    in
    Mono.MonoDestructor name monoPath monoType


{-| Specialize a path, computing the result type at each step.

The path is structured from leaf (root variable) outward, so we:

1.  Find the root and look up its type in VarTypes
2.  Walk back out through the path, computing types at each step

-}
specializePath : TOpt.Path -> Substitution -> VarTypes -> TypeEnv.GlobalTypeEnv -> Mono.MonoPath
specializePath path subst varTypes globalTypeEnv =
    case path of
        TOpt.Index index hint subPath ->
            let
                monoSubPath =
                    specializePath subPath subst varTypes globalTypeEnv

                containerType =
                    Mono.getMonoPathType monoSubPath

                resultType =
                    computeIndexProjectionType globalTypeEnv hint (Index.toMachine index) containerType
            in
            Mono.MonoIndex (Index.toMachine index) (hintToKind hint) resultType monoSubPath

        TOpt.ArrayIndex idx subPath ->
            let
                monoSubPath =
                    specializePath subPath subst varTypes globalTypeEnv

                containerType =
                    Mono.getMonoPathType monoSubPath

                -- ArrayIndex is used for array access, element type comes from the array's element type
                resultType =
                    computeArrayElementType containerType
            in
            Mono.MonoIndex idx (Mono.CustomContainer "") resultType monoSubPath

        TOpt.Field fieldName subPath ->
            let
                monoSubPath =
                    specializePath subPath subst varTypes globalTypeEnv

                recordType =
                    Mono.getMonoPathType monoSubPath

                resultType =
                    case recordType of
                        Mono.MRecord fields ->
                            case Dict.get identity fieldName fields of
                                Just fieldMonoType ->
                                    fieldMonoType

                                Nothing ->
                                    Utils.Crash.crash
                                        ("Specialize.specializePath: Field '"
                                            ++ fieldName
                                            ++ "' not found in record type. This is a compiler bug."
                                        )

                        _ ->
                            Utils.Crash.crash
                                ("Specialize.specializePath: Expected MRecord for field path but got: "
                                    ++ Mono.monoTypeToDebugString recordType
                                )
            in
            Mono.MonoField fieldName resultType monoSubPath

        TOpt.Unbox subPath ->
            let
                monoSubPath =
                    specializePath subPath subst varTypes globalTypeEnv

                containerType =
                    Mono.getMonoPathType monoSubPath

                -- Compute the result type by looking up the single field type of the container
                resultType =
                    computeUnboxResultType globalTypeEnv containerType
            in
            Mono.MonoUnbox resultType monoSubPath

        TOpt.Root name ->
            let
                rootType =
                    case Dict.get identity name varTypes of
                        Just ty ->
                            ty

                        Nothing ->
                            Utils.Crash.crash ("Specialize.specializePath: Root variable '" ++ name ++ "' not found in VarTypes. This is a compiler bug.")
            in
            Mono.MonoRoot name rootType


{-| Compute the result type of projecting at an index from a container.
-}
computeIndexProjectionType : TypeEnv.GlobalTypeEnv -> TOpt.ContainerHint -> Int -> Mono.MonoType -> Mono.MonoType
computeIndexProjectionType globalTypeEnv hint index containerType =
    case hint of
        TOpt.HintList ->
            case containerType of
                Mono.MList elemType ->
                    if index == 0 then
                        -- Index 0 is head: returns the element type
                        elemType

                    else
                        -- Index 1 is tail: returns the list type itself
                        containerType

                _ ->
                    Utils.Crash.crash ("Specialize.computeIndexProjectionType: HintList at index " ++ String.fromInt index ++ " - Expected MList but got: " ++ Mono.monoTypeToDebugString containerType)

        TOpt.HintTuple2 ->
            computeTupleElementType index containerType

        TOpt.HintTuple3 ->
            computeTupleElementType index containerType

        TOpt.HintCustom ctorName ->
            computeCustomFieldType globalTypeEnv ctorName index containerType


{-| Compute element type from a tuple at the given index.
-}
computeTupleElementType : Int -> Mono.MonoType -> Mono.MonoType
computeTupleElementType index containerType =
    case containerType of
        Mono.MTuple elementTypes ->
            case List.drop index elementTypes of
                elemType :: _ ->
                    elemType

                [] ->
                    Utils.Crash.crash ("Specialize.computeTupleElementType: Tuple index " ++ String.fromInt index ++ " out of bounds for tuple with " ++ String.fromInt (List.length elementTypes) ++ " elements")

        _ ->
            Utils.Crash.crash ("Specialize.computeTupleElementType: Expected MTuple but got: " ++ Mono.monoTypeToDebugString containerType)


{-| Compute field type from a custom type constructor at the given index.

This looks up the union definition to find the constructor's argument types,
then applies the type variable substitution based on the monomorphized type arguments.

-}
computeCustomFieldType : TypeEnv.GlobalTypeEnv -> Name -> Int -> Mono.MonoType -> Mono.MonoType
computeCustomFieldType globalTypeEnv ctorName index containerType =
    case containerType of
        Mono.MCustom moduleName typeName typeArgs ->
            case Analysis.lookupUnion globalTypeEnv moduleName typeName of
                Nothing ->
                    Utils.Crash.crash ("Specialize.computeCustomFieldType: Union not found: " ++ typeName)

                Just (Can.Union unionData) ->
                    case findCtorByName ctorName unionData.alts of
                        Nothing ->
                            Utils.Crash.crash ("Specialize.computeCustomFieldType: Constructor '" ++ ctorName ++ "' not found in union " ++ typeName)

                        Just (Can.Ctor ctorData) ->
                            case List.drop index ctorData.args of
                                canArgType :: _ ->
                                    -- Build substitution from union's type vars to concrete type args
                                    let
                                        typeVarSubst =
                                            List.map2 Tuple.pair unionData.vars typeArgs
                                                |> List.foldl (\( varName, monoArg ) acc -> Dict.insert identity varName monoArg acc) Dict.empty
                                    in
                                    TypeSubst.applySubst typeVarSubst canArgType

                                [] ->
                                    Utils.Crash.crash ("Specialize.computeCustomFieldType: Constructor arg index " ++ String.fromInt index ++ " out of bounds for " ++ ctorName)

        _ ->
            Utils.Crash.crash ("Specialize.computeCustomFieldType: Expected MCustom for ctor '" ++ ctorName ++ "' index " ++ String.fromInt index ++ " but got: " ++ Mono.monoTypeToDebugString containerType)


{-| Find a constructor by name in a list of alternatives.
-}
findCtorByName : Name -> List Can.Ctor -> Maybe Can.Ctor
findCtorByName targetName alts =
    List.filter (\(Can.Ctor ctorData) -> ctorData.name == targetName) alts
        |> List.head


{-| Compute the result type of unwrapping a single-constructor type.

For Unbox paths, we need to find the single field type of the container.
The container must be a single-constructor type (Can.Unbox option).

-}
computeUnboxResultType : TypeEnv.GlobalTypeEnv -> Mono.MonoType -> Mono.MonoType
computeUnboxResultType globalTypeEnv containerType =
    case containerType of
        Mono.MCustom moduleName typeName typeArgs ->
            case Analysis.lookupUnion globalTypeEnv moduleName typeName of
                Nothing ->
                    Utils.Crash.crash ("Specialize.computeUnboxResultType: Union not found: " ++ typeName)

                Just (Can.Union unionData) ->
                    -- Unbox is used for single-constructor types with a single field
                    case unionData.alts of
                        [ Can.Ctor ctorData ] ->
                            case ctorData.args of
                                [ canArgType ] ->
                                    -- Build substitution from union's type vars to concrete type args
                                    let
                                        typeVarSubst =
                                            List.map2 Tuple.pair unionData.vars typeArgs
                                                |> List.foldl (\( varName, monoArg ) acc -> Dict.insert identity varName monoArg acc) Dict.empty
                                    in
                                    TypeSubst.applySubst typeVarSubst canArgType

                                _ ->
                                    Utils.Crash.crash ("Specialize.computeUnboxResultType: Expected single-arg constructor but got " ++ String.fromInt (List.length ctorData.args) ++ " args for " ++ typeName)

                        _ ->
                            Utils.Crash.crash ("Specialize.computeUnboxResultType: Expected single-constructor type but got " ++ String.fromInt (List.length unionData.alts) ++ " constructors for " ++ typeName)

        _ ->
            Utils.Crash.crash ("Specialize.computeUnboxResultType: Expected MCustom but got: " ++ Mono.monoTypeToDebugString containerType)


{-| Compute element type from an array access.
-}
computeArrayElementType : Mono.MonoType -> Mono.MonoType
computeArrayElementType containerType =
    case containerType of
        Mono.MCustom _ "Array" [ elemType ] ->
            elemType

        _ ->
            Utils.Crash.crash ("Specialize.computeArrayElementType: Expected Array type but got: " ++ Mono.monoTypeToDebugString containerType)


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

        TOpt.HintCustom ctorName ->
            Mono.CustomContainer ctorName


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


specializeRecordFields : Dict String Name TOpt.Expr -> Substitution -> MonoState -> ( List ( Name, Mono.MonoExpr ), MonoState )
specializeRecordFields fields subst state =
    Dict.foldl compare
        (\name expr ( acc, st ) ->
            let
                ( monoExpr, newSt ) =
                    specializeExpr expr subst st
            in
            ( ( name, monoExpr ) :: acc, newSt )
        )
        ( [], state )
        fields


specializeTrackedRecordFields : Dict String (A.Located Name) TOpt.Expr -> Substitution -> MonoState -> ( List ( Name, Mono.MonoExpr ), MonoState )
specializeTrackedRecordFields fields subst state =
    Dict.foldl A.compareLocated
        (\locName expr ( acc, st ) ->
            let
                name =
                    A.toValue locName

                ( monoExpr, newSt ) =
                    specializeExpr expr subst st
            in
            ( ( name, monoExpr ) :: acc, newSt )
        )
        ( [], state )
        fields


specializeUpdates : Dict String (A.Located Name) TOpt.Expr -> Substitution -> MonoState -> ( List ( Name, Mono.MonoExpr ), MonoState )
specializeUpdates updates subst state =
    Dict.foldl A.compareLocated
        (\locName expr ( acc, st ) ->
            let
                fieldName =
                    A.toValue locName

                ( monoExpr, newSt ) =
                    specializeExpr expr subst st
            in
            ( ( fieldName, monoExpr ) :: acc, newSt )
        )
        ( [], state )
        updates


{-| Specialize a function argument by applying type substitution.
-}
specializeArg : Substitution -> ( A.Located Name, Can.Type ) -> ( Name, Mono.MonoType )
specializeArg subst ( locName, canType ) =
    let
        name =
            A.toValue locName

        monoType =
            TypeSubst.applySubst subst canType
    in
    ( name, monoType )


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


{-| Build a constructor shape from name, tag, arity, and monomorphic type information.
-}
buildCtorShapeFromArity : Name.Name -> Int -> Int -> Mono.MonoType -> Mono.CtorShape
buildCtorShapeFromArity ctorName tag arity ctorMonoType =
    let
        fieldTypes =
            extractFieldTypes arity ctorMonoType
    in
    { name = ctorName
    , tag = tag
    , fieldTypes = fieldTypes
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
