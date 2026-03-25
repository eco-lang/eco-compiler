module Compiler.MonoDirect.Specialize exposing (specializeNode)

{-| Solver-directed expression specialization for MonoDirect.

Uses the solver snapshot for type resolution instead of TypeSubst
string-based substitution. Every expression's type is resolved through
the solver's union-find via LocalView.monoTypeOf.

@docs specializeNode

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.DecisionTree.TypedPath as TypedPath
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.BitSet as BitSet
import Compiler.Data.Index as Index
import Compiler.Data.Name exposing (Name)
import Compiler.MonoDirect.State as State exposing (MonoDirectState, VarEnv)
import Compiler.Monomorphize.Analysis as Analysis
import Compiler.Monomorphize.Closure as Closure
import Compiler.Monomorphize.KernelAbi as KernelAbi
import Compiler.Monomorphize.Registry as Registry
import Compiler.Monomorphize.TypeSubst as TypeSubst
import Compiler.Reporting.Annotation as A
import Compiler.Type.SolverSnapshot as SolverSnapshot exposing (LocalView, SolverSnapshot)
import Data.Map as DMap
import Dict exposing (Dict)
import System.TypeCheck.IO as IO
import Utils.Crash


{-| Classifies a call argument for two-phase specialization.
Accessors and number-boxed kernels are deferred until callee parameter types are known.
-}
type ProcessedArg
    = ResolvedArg Mono.MonoExpr
    | PendingAccessor A.Region Name Can.Type
    | PendingKernel A.Region String String TOpt.Meta
    | LocalFunArg Name Can.Type


{-| Specialize a TOpt.Node into a MonoNode using solver-driven type resolution.
-}
specializeNode : SolverSnapshot -> Name -> TOpt.Node -> Mono.MonoType -> MonoDirectState -> ( Mono.MonoNode, MonoDirectState )
specializeNode snapshot ctorName node requestedMonoType state =
    case node of
        TOpt.Define expr _ meta ->
            specializeDefineNode snapshot expr meta requestedMonoType state

        TOpt.TrackedDefine _ expr _ meta ->
            specializeDefineNode snapshot expr meta requestedMonoType state

        TOpt.Ctor index arity _ ->
            let
                monoType =
                    Mono.forceCNumberToInt requestedMonoType

                tag =
                    Index.toMachine index

                ctorResultType =
                    extractCtorResultType arity monoType

                shape =
                    buildCtorShapeFromArity ctorName tag arity monoType
            in
            ( Mono.MonoCtor shape ctorResultType, state )

        TOpt.Enum index _ ->
            ( Mono.MonoEnum (Index.toMachine index) requestedMonoType, state )

        TOpt.Box _ ->
            let
                monoType =
                    Mono.forceCNumberToInt requestedMonoType

                ctorResultType =
                    extractCtorResultType 1 monoType

                shape =
                    buildCtorShapeFromArity ctorName 0 1 monoType
            in
            ( Mono.MonoCtor shape ctorResultType, state )

        TOpt.Link linkedGlobal ->
            let
                toptGlobal =
                    linkedGlobal
            in
            case DMap.get TOpt.toComparableGlobal toptGlobal state.toptNodes of
                Nothing ->
                    ( Mono.MonoExtern requestedMonoType, state )

                Just linkedNode ->
                    let
                        linkedName =
                            case linkedGlobal of
                                TOpt.Global _ n ->
                                    n
                    in
                    specializeNode snapshot linkedName linkedNode requestedMonoType state

        TOpt.Kernel _ _ ->
            ( Mono.MonoExtern requestedMonoType, state )

        TOpt.Manager _ ->
            let
                homeName =
                    case state.currentModule of
                        IO.Canonical _ modName ->
                            modName
            in
            ( Mono.MonoManagerLeaf homeName requestedMonoType, state )

        TOpt.Cycle names valueDefs funcDefs _ ->
            specializeCycle snapshot names valueDefs funcDefs requestedMonoType state

        TOpt.PortIncoming expr _ meta ->
            specializePortNode snapshot expr meta requestedMonoType Mono.MonoPortIncoming state

        TOpt.PortOutgoing expr _ meta ->
            specializePortNode snapshot expr meta requestedMonoType Mono.MonoPortOutgoing state


specializeDefineNode : SolverSnapshot -> TOpt.Expr -> TOpt.Meta -> Mono.MonoType -> MonoDirectState -> ( Mono.MonoNode, MonoDirectState )
specializeDefineNode snapshot expr meta requestedMonoType state =
    let
        -- Build substitution from the node's Can.Type and concrete MonoType.
        -- This serves as fallback for any sub-expressions with disconnected tvars.
        nodeSubst =
            TypeSubst.unifyExtend meta.tipe requestedMonoType Dict.empty
    in
    case meta.tvar of
        Just annotVar ->
            SolverSnapshot.specializeChainedWithSubst snapshot
                [ ( annotVar, requestedMonoType ) ]
                nodeSubst
                (\view ->
                    let
                        stateWithPush =
                            { state | specStack = ( annotVar, requestedMonoType ) :: state.specStack }

                        ( monoExpr, state1 ) =
                            specializeExpr view snapshot expr stateWithPush

                        statePopped =
                            { state1 | specStack = state.specStack }
                    in
                    ( Mono.MonoDefine monoExpr (Mono.typeOf monoExpr), statePopped )
                )

        Nothing ->
            if isMonomorphicCanType meta.tipe then
                -- Truly monomorphic synthetic node (e.g. record alias constructor).
                -- Safe to use empty unification context.
                SolverSnapshot.withLocalUnification snapshot
                    []
                    []
                    (\view ->
                        let
                            ( monoExpr, state1 ) =
                                specializeExpr view snapshot expr state
                        in
                        ( Mono.MonoDefine monoExpr (Mono.typeOf monoExpr), state1 )
                    )

            else
                -- Polymorphic node without solver tvar. Use substitution-based fallback.
                SolverSnapshot.specializeChainedWithSubst snapshot
                    []
                    nodeSubst
                    (\view ->
                        let
                            ( monoExpr, state1 ) =
                                specializeExpr view snapshot expr state
                        in
                        ( Mono.MonoDefine monoExpr (Mono.typeOf monoExpr), state1 )
                    )


specializePortNode :
    SolverSnapshot
    -> TOpt.Expr
    -> TOpt.Meta
    -> Mono.MonoType
    -> (Mono.MonoExpr -> Mono.MonoType -> Mono.MonoNode)
    -> MonoDirectState
    -> ( Mono.MonoNode, MonoDirectState )
specializePortNode snapshot expr meta requestedMonoType nodeConstructor state =
    case meta.tvar of
        Just annotVar ->
            SolverSnapshot.specializeFunction snapshot
                annotVar
                requestedMonoType
                (\view ->
                    let
                        ( monoExpr, state1 ) =
                            specializeExpr view snapshot expr state
                    in
                    ( nodeConstructor monoExpr requestedMonoType, state1 )
                )

        Nothing ->
            if isMonomorphicCanType meta.tipe then
                SolverSnapshot.withLocalUnification snapshot
                    []
                    []
                    (\view ->
                        let
                            ( monoExpr, state1 ) =
                                specializeExpr view snapshot expr state
                        in
                        ( nodeConstructor monoExpr requestedMonoType, state1 )
                    )

            else
                Utils.Crash.crash
                    "MonoDirect.specializePortNode: missing tvar for polymorphic port"



-- ========== TYPE RESOLUTION ==========


{-| Resolve a TOpt expression's type through the solver LocalView.
-}
resolveType : LocalView -> TOpt.Meta -> Mono.MonoType
resolveType view meta =
    let
        rawType =
            case meta.tvar of
                Just tvar ->
                    view.monoTypeOf tvar

                Nothing ->
                    if isMonomorphicCanType meta.tipe then
                        KernelAbi.canTypeToMonoType_preserveVars meta.tipe

                    else
                        TypeSubst.canTypeToMonoType view.subst meta.tipe
    in
    Mono.forceCNumberToInt rawType



-- ========== EXPRESSION SPECIALIZATION ==========


specializeExpr : LocalView -> SolverSnapshot -> TOpt.Expr -> MonoDirectState -> ( Mono.MonoExpr, MonoDirectState )
specializeExpr view snapshot expr state =
    case expr of
        -- Literals
        TOpt.Bool _ value _ ->
            ( Mono.MonoLiteral (Mono.LBool value) Mono.MBool, state )

        TOpt.Chr _ value _ ->
            ( Mono.MonoLiteral (Mono.LChar value) Mono.MChar, state )

        TOpt.Str _ value _ ->
            ( Mono.MonoLiteral (Mono.LStr value) Mono.MString, state )

        TOpt.Int _ value meta ->
            let
                monoType =
                    resolveType view meta
            in
            case monoType of
                Mono.MFloat ->
                    ( Mono.MonoLiteral (Mono.LFloat (toFloat value)) monoType, state )

                _ ->
                    ( Mono.MonoLiteral (Mono.LInt value) monoType, state )

        TOpt.Float _ value meta ->
            ( Mono.MonoLiteral (Mono.LFloat value) (resolveType view meta), state )

        -- Local variables
        TOpt.VarLocal name meta ->
            let
                monoType =
                    case State.lookupVar name state.varEnv of
                        Just t ->
                            t

                        Nothing ->
                            resolveType view meta
            in
            if State.isLocalMultiTarget name state then
                let
                    ( freshName, state1 ) =
                        State.getOrCreateLocalInstance name monoType view.subst state
                in
                ( Mono.MonoVarLocal freshName monoType, state1 )

            else
                ( Mono.MonoVarLocal name monoType, state )

        TOpt.TrackedVarLocal _ name meta ->
            let
                monoType =
                    case State.lookupVar name state.varEnv of
                        Just t ->
                            t

                        Nothing ->
                            resolveType view meta
            in
            if State.isLocalMultiTarget name state then
                let
                    ( freshName, state1 ) =
                        State.getOrCreateLocalInstance name monoType view.subst state
                in
                ( Mono.MonoVarLocal freshName monoType, state1 )

            else
                ( Mono.MonoVarLocal name monoType, state )

        -- Global references
        TOpt.VarGlobal region global meta ->
            let
                monoType =
                    resolveType view meta

                monoGlobal =
                    toptGlobalToMono global

                ( specId, state1 ) =
                    enqueueSpec monoGlobal monoType Nothing state
            in
            ( Mono.MonoVarGlobal region specId monoType, state1 )

        TOpt.VarEnum region global _ meta ->
            let
                monoType =
                    resolveType view meta

                monoGlobal =
                    toptGlobalToMono global

                ( specId, state1 ) =
                    enqueueSpec monoGlobal monoType Nothing state
            in
            ( Mono.MonoVarGlobal region specId monoType, state1 )

        TOpt.VarBox region global meta ->
            let
                monoType =
                    resolveType view meta

                monoGlobal =
                    toptGlobalToMono global

                ( specId, state1 ) =
                    enqueueSpec monoGlobal monoType Nothing state
            in
            ( Mono.MonoVarGlobal region specId monoType, state1 )

        TOpt.VarCycle region canonical name meta ->
            let
                monoType =
                    resolveType view meta

                monoGlobal =
                    Mono.Global canonical name

                ( specId, state1 ) =
                    enqueueSpec monoGlobal monoType Nothing state
            in
            ( Mono.MonoVarGlobal region specId monoType, state1 )

        TOpt.VarDebug region name _ _ meta ->
            let
                funcMonoType =
                    deriveKernelAbiTypeDirect ( "Debug", name ) meta view
            in
            ( Mono.MonoVarKernel region "Debug" name funcMonoType, state )

        TOpt.VarKernel region home name meta ->
            let
                funcMonoType =
                    deriveKernelAbiTypeDirect ( home, name ) meta view
            in
            ( Mono.MonoVarKernel region home name funcMonoType, state )

        -- Collections
        TOpt.List region items meta ->
            let
                monoType0 =
                    resolveType view meta

                ( monoItems, state1 ) =
                    specializeExprs view snapshot items state

                monoType =
                    if Mono.containsAnyMVar monoType0 then
                        case monoItems of
                            first :: _ ->
                                Mono.MList (Mono.typeOf first)

                            [] ->
                                monoType0

                    else
                        monoType0
            in
            ( Mono.MonoList region monoItems monoType, state1 )

        -- Functions/closures
        TOpt.Function params body meta ->
            specializeLambda view snapshot params body meta state

        TOpt.TrackedFunction params body meta ->
            specializeTrackedLambda view snapshot params body meta state

        -- Calls
        TOpt.Call region func args meta ->
            specializeCall view snapshot region func args meta state

        TOpt.TailCall name args meta ->
            let
                resultType =
                    resolveType view meta

                ( monoArgs, state1 ) =
                    specializeNamedExprs view snapshot args state
            in
            ( Mono.MonoTailCall name monoArgs resultType, state1 )

        -- Control flow
        TOpt.If branches final meta ->
            let
                monoType0 =
                    resolveType view meta

                ( monoBranches, state1 ) =
                    specializeBranches view snapshot branches state

                ( monoFinal, state2 ) =
                    specializeExpr view snapshot final state1

                monoType =
                    if Mono.containsAnyMVar monoType0 then
                        Mono.typeOf monoFinal

                    else
                        monoType0
            in
            ( Mono.MonoIf monoBranches monoFinal monoType, state2 )

        TOpt.Let def body meta ->
            specializeLet view snapshot def body meta state

        TOpt.Destruct destructor body meta ->
            let
                monoType0 =
                    resolveType view meta

                monoDestructor =
                    specializeDestructor view state.varEnv state.globalTypeEnv destructor

                -- Insert destructor binding into varEnv
                (TOpt.Destructor dName _ _) =
                    destructor

                (Mono.MonoDestructor _ monoPath _) =
                    monoDestructor

                destructorType =
                    Mono.getMonoPathType monoPath

                state1 =
                    { state | varEnv = State.insertVar dName destructorType state.varEnv }

                ( monoBody, state2 ) =
                    specializeExpr view snapshot body state1

                monoType =
                    if Mono.containsAnyMVar monoType0 then
                        Mono.typeOf monoBody

                    else
                        monoType0
            in
            ( Mono.MonoDestruct monoDestructor monoBody monoType, state2 )

        TOpt.Case scrutName label decider jumps meta ->
            let
                monoType0 =
                    resolveType view meta

                savedVarEnv =
                    state.varEnv

                ( monoDecider, state1 ) =
                    specializeDecider label view snapshot decider state

                state1WithResetVarEnv =
                    { state1 | varEnv = savedVarEnv }

                ( monoJumps, state2 ) =
                    specializeJumps view snapshot jumps state1WithResetVarEnv

                monoType =
                    if Mono.containsAnyMVar monoType0 then
                        inferCaseType monoJumps monoDecider monoType0

                    else
                        monoType0
            in
            ( Mono.MonoCase scrutName label monoDecider monoJumps monoType, state2 )

        -- Records
        TOpt.Record fields meta ->
            let
                monoType =
                    resolveType view meta

                ( monoFields, state1 ) =
                    specializeFieldExprs view snapshot fields state
            in
            ( Mono.MonoRecordCreate monoFields monoType, state1 )

        TOpt.TrackedRecord _ fields meta ->
            let
                monoType =
                    resolveType view meta

                ( monoFields, state1 ) =
                    specializeLocatedFieldExprs view snapshot fields state
            in
            ( Mono.MonoRecordCreate monoFields monoType, state1 )

        TOpt.Accessor region fieldName meta ->
            let
                monoType =
                    resolveType view meta

                monoGlobal =
                    Mono.Accessor fieldName

                ( specId, state1 ) =
                    enqueueSpec monoGlobal monoType Nothing state
            in
            ( Mono.MonoVarGlobal region specId monoType, state1 )

        TOpt.Access recordExpr _ fieldName meta ->
            let
                fieldMonoType =
                    resolveType view meta

                ( monoRecord, state1 ) =
                    specializeExpr view snapshot recordExpr state
            in
            ( Mono.MonoRecordAccess monoRecord fieldName fieldMonoType, state1 )

        TOpt.Update _ recordExpr updates meta ->
            let
                monoType =
                    resolveType view meta

                ( monoRecord, state1 ) =
                    specializeExpr view snapshot recordExpr state

                ( monoUpdates, state2 ) =
                    specializeLocatedFieldExprs view snapshot updates state1
            in
            ( Mono.MonoRecordUpdate monoRecord monoUpdates monoType, state2 )

        -- Tuples
        TOpt.Tuple region a b rest meta ->
            let
                monoType0 =
                    resolveType view meta

                ( monoA, state1 ) =
                    specializeExpr view snapshot a state

                ( monoB, state2 ) =
                    specializeExpr view snapshot b state1

                ( monoRest, state3 ) =
                    specializeExprs view snapshot rest state2

                monoType =
                    if Mono.containsAnyMVar monoType0 then
                        Mono.MTuple (List.map Mono.typeOf (monoA :: monoB :: monoRest))

                    else
                        monoType0
            in
            ( Mono.MonoTupleCreate region (monoA :: monoB :: monoRest) monoType, state3 )

        -- Unit
        TOpt.Unit _ ->
            ( Mono.MonoUnit, state )

        -- Shader
        TOpt.Shader _ _ _ _ ->
            ( Mono.MonoUnit, state )



-- ========== CALL SPECIALIZATION ==========


buildCurriedFuncType : List Mono.MonoType -> Mono.MonoType -> Mono.MonoType
buildCurriedFuncType argTypes resultType =
    List.foldr
        (\argTy acc -> Mono.MFunction [ argTy ] acc)
        resultType
        argTypes


specializeCall : LocalView -> SolverSnapshot -> A.Region -> TOpt.Expr -> List TOpt.Expr -> TOpt.Meta -> MonoDirectState -> ( Mono.MonoExpr, MonoDirectState )
specializeCall view snapshot region func args meta state =
    let
        resultType =
            resolveType view meta

        -- Phase 1: classify args, deferring accessors/kernels/local-multi
        ( processedArgs, argTypes, state1 ) =
            processCallArgs view snapshot args state
    in
    case func of
        TOpt.VarGlobal funcRegion global funcMeta ->
            let
                funcMonoType =
                    case funcMeta.tvar of
                        Just _ ->
                            resolveType view funcMeta

                        Nothing ->
                            buildCurriedFuncType argTypes resultType

                ( paramTypes, _ ) =
                    Closure.flattenFunctionType funcMonoType

                monoGlobal =
                    toptGlobalToMono global

                ( specId, state2 ) =
                    enqueueSpec monoGlobal funcMonoType Nothing state1

                monoFunc =
                    Mono.MonoVarGlobal funcRegion specId funcMonoType

                -- Phase 2: resolve deferred args using callee param types
                ( monoArgs, state3 ) =
                    finishProcessedArgs view processedArgs paramTypes state2
            in
            ( Mono.MonoCall region monoFunc monoArgs resultType Mono.defaultCallInfo, state3 )

        TOpt.VarKernel funcRegion home name funcMeta ->
            let
                funcMonoType =
                    deriveKernelAbiTypeDirect ( home, name ) funcMeta view

                ( paramTypes, _ ) =
                    Closure.flattenFunctionType funcMonoType

                monoFunc =
                    Mono.MonoVarKernel funcRegion home name funcMonoType

                ( monoArgs, state2 ) =
                    finishProcessedArgs view processedArgs paramTypes state1
            in
            ( Mono.MonoCall region monoFunc monoArgs resultType Mono.defaultCallInfo, state2 )

        TOpt.VarDebug funcRegion name _ _ funcMeta ->
            let
                funcMonoType =
                    deriveKernelAbiTypeDirect ( "Debug", name ) funcMeta view

                ( paramTypes, _ ) =
                    Closure.flattenFunctionType funcMonoType

                monoFunc =
                    Mono.MonoVarKernel funcRegion "Debug" name funcMonoType

                ( monoArgs, state2 ) =
                    finishProcessedArgs view processedArgs paramTypes state1
            in
            ( Mono.MonoCall region monoFunc monoArgs resultType Mono.defaultCallInfo, state2 )

        TOpt.VarLocal name funcMeta ->
            if State.isLocalMultiTarget name state1 then
                let
                    -- Solver-driven: derive function type from tvar when available
                    funcMonoType =
                        case funcMeta.tvar of
                            Just tvar ->
                                Mono.forceCNumberToInt (view.monoTypeOf tvar)

                            Nothing ->
                                buildCurriedFuncType argTypes resultType

                    ( paramTypes, _ ) =
                        Closure.flattenFunctionType funcMonoType

                    ( freshName, state2 ) =
                        State.getOrCreateLocalInstance name funcMonoType view.subst state1

                    monoFunc =
                        Mono.MonoVarLocal freshName funcMonoType

                    ( monoArgs, state3 ) =
                        finishProcessedArgs view processedArgs paramTypes state2
                in
                ( Mono.MonoCall region monoFunc monoArgs resultType Mono.defaultCallInfo, state3 )

            else
                let
                    ( monoFunc, state2 ) =
                        specializeExpr view snapshot func state1

                    funcMonoType =
                        Mono.typeOf monoFunc

                    ( paramTypes, _ ) =
                        Closure.flattenFunctionType funcMonoType

                    ( monoArgs, state3 ) =
                        finishProcessedArgs view processedArgs paramTypes state2
                in
                ( Mono.MonoCall region monoFunc monoArgs resultType Mono.defaultCallInfo, state3 )

        TOpt.TrackedVarLocal _ name funcMeta ->
            if State.isLocalMultiTarget name state1 then
                let
                    -- Solver-driven: derive function type from tvar when available
                    funcMonoType =
                        case funcMeta.tvar of
                            Just tvar ->
                                Mono.forceCNumberToInt (view.monoTypeOf tvar)

                            Nothing ->
                                buildCurriedFuncType argTypes resultType

                    ( paramTypes, _ ) =
                        Closure.flattenFunctionType funcMonoType

                    ( freshName, state2 ) =
                        State.getOrCreateLocalInstance name funcMonoType view.subst state1

                    monoFunc =
                        Mono.MonoVarLocal freshName funcMonoType

                    ( monoArgs, state3 ) =
                        finishProcessedArgs view processedArgs paramTypes state2
                in
                ( Mono.MonoCall region monoFunc monoArgs resultType Mono.defaultCallInfo, state3 )

            else
                let
                    ( monoFunc, state2 ) =
                        specializeExpr view snapshot func state1

                    funcMonoType =
                        Mono.typeOf monoFunc

                    ( paramTypes, _ ) =
                        Closure.flattenFunctionType funcMonoType

                    ( monoArgs, state3 ) =
                        finishProcessedArgs view processedArgs paramTypes state2
                in
                ( Mono.MonoCall region monoFunc monoArgs resultType Mono.defaultCallInfo, state3 )

        _ ->
            let
                ( monoFunc, state2 ) =
                    specializeExpr view snapshot func state1

                funcMonoType =
                    Mono.typeOf monoFunc

                ( paramTypes, _ ) =
                    Closure.flattenFunctionType funcMonoType

                ( monoArgs, state3 ) =
                    finishProcessedArgs view processedArgs paramTypes state2
            in
            ( Mono.MonoCall region monoFunc monoArgs resultType Mono.defaultCallInfo, state3 )


processCallArgs :
    LocalView
    -> SolverSnapshot
    -> List TOpt.Expr
    -> MonoDirectState
    -> ( List ProcessedArg, List Mono.MonoType, MonoDirectState )
processCallArgs view snapshot args state0 =
    List.foldr
        (\arg ( accArgs, accTypes, st ) ->
            case arg of
                TOpt.Accessor accessorRegion fieldName accessorMeta ->
                    let
                        monoType =
                            resolveType view accessorMeta
                    in
                    ( PendingAccessor accessorRegion fieldName accessorMeta.tipe :: accArgs
                    , monoType :: accTypes
                    , st
                    )

                TOpt.VarKernel kernelRegion home name kernelMeta ->
                    case KernelAbi.deriveKernelAbiMode ( home, name ) kernelMeta.tipe of
                        KernelAbi.NumberBoxed ->
                            let
                                monoType =
                                    resolveType view kernelMeta
                            in
                            ( PendingKernel kernelRegion home name kernelMeta :: accArgs
                            , monoType :: accTypes
                            , st
                            )

                        _ ->
                            let
                                ( monoExpr, st1 ) =
                                    specializeExpr view snapshot arg st
                            in
                            ( ResolvedArg monoExpr :: accArgs
                            , Mono.typeOf monoExpr :: accTypes
                            , st1
                            )

                TOpt.VarLocal name localMeta ->
                    if State.isLocalMultiTarget name st then
                        let
                            monoType =
                                resolveType view localMeta
                        in
                        ( LocalFunArg name localMeta.tipe :: accArgs
                        , monoType :: accTypes
                        , st
                        )

                    else
                        let
                            ( monoExpr, st1 ) =
                                specializeExpr view snapshot arg st
                        in
                        ( ResolvedArg monoExpr :: accArgs
                        , Mono.typeOf monoExpr :: accTypes
                        , st1
                        )

                TOpt.TrackedVarLocal _ name trackedMeta ->
                    if State.isLocalMultiTarget name st then
                        let
                            monoType =
                                resolveType view trackedMeta
                        in
                        ( LocalFunArg name trackedMeta.tipe :: accArgs
                        , monoType :: accTypes
                        , st
                        )

                    else
                        let
                            ( monoExpr, st1 ) =
                                specializeExpr view snapshot arg st
                        in
                        ( ResolvedArg monoExpr :: accArgs
                        , Mono.typeOf monoExpr :: accTypes
                        , st1
                        )

                _ ->
                    let
                        ( monoExpr, st1 ) =
                            specializeExpr view snapshot arg st
                    in
                    ( ResolvedArg monoExpr :: accArgs
                    , Mono.typeOf monoExpr :: accTypes
                    , st1
                    )
        )
        ( [], [], state0 )
        args


finishProcessedArgs :
    LocalView
    -> List ProcessedArg
    -> List Mono.MonoType
    -> MonoDirectState
    -> ( List Mono.MonoExpr, MonoDirectState )
finishProcessedArgs view processedArgs paramTypes state0 =
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
                    finishProcessedArg view processedArg maybeParam st
            in
            ( monoExpr :: acc, st1, rest )

        ( revArgs, finalState, _ ) =
            List.foldl step ( [], state0, paramTypes ) processedArgs
    in
    ( List.reverse revArgs, finalState )


finishProcessedArg :
    LocalView
    -> ProcessedArg
    -> Maybe Mono.MonoType
    -> MonoDirectState
    -> ( Mono.MonoExpr, MonoDirectState )
finishProcessedArg view processedArg maybeParamType state =
    case processedArg of
        ResolvedArg monoExpr ->
            ( monoExpr, state )

        PendingAccessor region fieldName _ ->
            case maybeParamType of
                Just paramType ->
                    resolveAccessor region fieldName paramType state

                Nothing ->
                    Utils.Crash.crash
                        ("MonoDirect.finishProcessedArg: Accessor ."
                            ++ fieldName
                            ++ " did not receive parameter type"
                        )

        PendingKernel region home name kernelMeta ->
            let
                kernelMonoType =
                    deriveKernelAbiTypeDirect ( home, name ) kernelMeta view
            in
            ( Mono.MonoVarKernel region home name kernelMonoType, state )

        LocalFunArg name _ ->
            case maybeParamType of
                Just paramType ->
                    ( Mono.MonoVarLocal name paramType, state )

                Nothing ->
                    Utils.Crash.crash
                        ("MonoDirect.finishProcessedArg: LocalFunArg "
                            ++ name
                            ++ " with no parameter type"
                        )


resolveAccessor :
    A.Region
    -> Name
    -> Mono.MonoType
    -> MonoDirectState
    -> ( Mono.MonoExpr, MonoDirectState )
resolveAccessor region fieldName paramType state =
    let
        recordFields =
            extractRecordFields paramType

        fieldType =
            case Dict.get fieldName recordFields of
                Just ft ->
                    ft

                Nothing ->
                    Utils.Crash.crash
                        ("MonoDirect.resolveAccessor: field '"
                            ++ fieldName
                            ++ "' not in record type: "
                            ++ Mono.monoTypeToDebugString paramType
                        )

        recordType =
            Mono.MRecord recordFields

        accessorMonoType =
            Mono.MFunction [ recordType ] fieldType

        accessorGlobal =
            Mono.Accessor fieldName

        ( specId, state1 ) =
            enqueueSpec accessorGlobal accessorMonoType Nothing state
    in
    ( Mono.MonoVarGlobal region specId accessorMonoType, state1 )


extractRecordFields : Mono.MonoType -> Dict Name Mono.MonoType
extractRecordFields monoType =
    case monoType of
        Mono.MRecord fields ->
            fields

        Mono.MFunction args _ ->
            args
                |> List.filterMap
                    (\arg ->
                        case arg of
                            Mono.MRecord fields ->
                                Just fields

                            _ ->
                                Nothing
                    )
                |> List.head
                |> Maybe.withDefault Dict.empty

        _ ->
            Dict.empty



-- ========== LAMBDA SPECIALIZATION ==========


specializeLambda : LocalView -> SolverSnapshot -> List ( Name, Can.Type ) -> TOpt.Expr -> TOpt.Meta -> MonoDirectState -> ( Mono.MonoExpr, MonoDirectState )
specializeLambda view snapshot params body meta state =
    let
        funcMonoType =
            resolveType view meta

        ( paramMonoTypes, _ ) =
            Closure.flattenFunctionType funcMonoType

        monoParams =
            List.map2
                (\( name, _ ) paramType -> ( name, paramType ))
                params
                (padOrTruncate paramMonoTypes (List.length params))

        -- Push var frame with params
        state1 =
            { state | varEnv = State.pushFrame state.varEnv }

        state2 =
            List.foldl
                (\( name, monoType ) s -> { s | varEnv = State.insertVar name monoType s.varEnv })
                state1
                monoParams

        ( monoBody, state3 ) =
            specializeExpr view snapshot body state2

        state4 =
            { state3 | varEnv = State.popFrame state3.varEnv }

        lambdaId =
            Mono.AnonymousLambda state4.currentModule state4.lambdaCounter

        state5 =
            { state4 | lambdaCounter = state4.lambdaCounter + 1 }

        captures =
            Closure.computeClosureCaptures monoParams monoBody

        closureInfo =
            { lambdaId = lambdaId
            , captures = captures
            , params = monoParams
            , closureKind = Nothing
            , captureAbi = Nothing
            }
    in
    ( Mono.MonoClosure closureInfo monoBody funcMonoType, state5 )


specializeTrackedLambda : LocalView -> SolverSnapshot -> List ( A.Located Name, Can.Type ) -> TOpt.Expr -> TOpt.Meta -> MonoDirectState -> ( Mono.MonoExpr, MonoDirectState )
specializeTrackedLambda view snapshot params body meta state =
    let
        unlocatedParams =
            List.map (\( A.At _ name, tipe ) -> ( name, tipe )) params
    in
    specializeLambda view snapshot unlocatedParams body meta state



-- ========== LET SPECIALIZATION ==========


specializeLet : LocalView -> SolverSnapshot -> TOpt.Def -> TOpt.Expr -> TOpt.Meta -> MonoDirectState -> ( Mono.MonoExpr, MonoDirectState )
specializeLet view snapshot def body meta state =
    let
        monoType =
            resolveType view meta
    in
    case def of
        TOpt.Def _ defName defExpr defCanType ->
            case defCanType of
                Can.TLambda _ _ ->
                    specializeLetFuncDef view snapshot defName defExpr body monoType state

                _ ->
                    case defExpr of
                        TOpt.Accessor _ _ accessorMeta ->
                            -- Accessor alias: compute type from solver, bind before body
                            let
                                defMonoType =
                                    resolveType view accessorMeta

                                state1 =
                                    { state | varEnv = State.insertVar defName defMonoType state.varEnv }

                                ( monoBody, state2 ) =
                                    specializeExpr view snapshot body state1

                                -- Specialize the accessor expression after body
                                ( monoDefExpr, state3 ) =
                                    specializeExpr view snapshot defExpr state2

                                monoDef =
                                    Mono.MonoDef defName monoDefExpr

                                letResultType =
                                    if Mono.containsAnyMVar monoType then
                                        Mono.typeOf monoBody

                                    else
                                        monoType
                            in
                            ( Mono.MonoLet monoDef monoBody letResultType, state3 )

                        _ ->
                            let
                                ( monoDefExpr, state1 ) =
                                    specializeExpr view snapshot defExpr state

                                defMonoType =
                                    Mono.typeOf monoDefExpr

                                state2 =
                                    { state1 | varEnv = State.insertVar defName defMonoType state1.varEnv }

                                ( monoBody, state3 ) =
                                    specializeExpr view snapshot body state2

                                monoDef =
                                    Mono.MonoDef defName monoDefExpr

                                letResultType =
                                    if Mono.containsAnyMVar monoType then
                                        Mono.typeOf monoBody

                                    else
                                        monoType
                            in
                            ( Mono.MonoLet monoDef monoBody letResultType, state3 )

        TOpt.TailDef _ defName defParams defBody defCanType defTvar ->
            specializeLetTailDef view snapshot defName defParams defBody defCanType defTvar body monoType state


specializeLetTailDef :
    LocalView
    -> SolverSnapshot
    -> Name
    -> List ( A.Located Name, Can.Type )
    -> TOpt.Expr
    -> Can.Type
    -> Maybe SolverSnapshot.TypeVar
    -> TOpt.Expr
    -> Mono.MonoType
    -> MonoDirectState
    -> ( Mono.MonoExpr, MonoDirectState )
specializeLetTailDef view snapshot defName defParams defBody defCanType defTvar body monoType state =
    let
        funcMonoType0 =
            resolveType view { tipe = defCanType, tvar = defTvar }
    in
    if Mono.containsAnyMVar funcMonoType0 then
        -- Polymorphic TailDef: use call-site discovery (like specializeLetFuncDef)
        let
            newEntry =
                { defName = defName, instances = Dict.empty }

            stateForBody =
                { state
                    | localMulti = newEntry :: state.localMulti
                    , varEnv = State.insertVar defName funcMonoType0 state.varEnv
                }

            ( _, stateAfterBody ) =
                specializeExpr view snapshot body stateForBody
        in
        case stateAfterBody.localMulti of
            topEntry :: restOfStack ->
                if Dict.isEmpty topEntry.instances then
                    -- No calls: single instance with resolved type
                    specializeLetTailDefSingle view
                        snapshot
                        defName
                        defParams
                        defBody
                        defCanType
                        defTvar
                        funcMonoType0
                        body
                        monoType
                        { stateAfterBody | localMulti = restOfStack }

                else
                    -- Multi-instance: specialize per discovered instance
                    let
                        instancesList =
                            Dict.values topEntry.instances
                                |> List.sortBy (\info -> Mono.monoTypeToDebugString info.monoType)

                        statePopped =
                            { stateAfterBody | localMulti = restOfStack }

                        ( instanceDefs, stateWithDefs ) =
                            List.foldl
                                (\info ( defsAcc, stAcc ) ->
                                    let
                                        ( monoDef, st1 ) =
                                            specializeTailDefForInstance view
                                                snapshot
                                                defName
                                                defParams
                                                defBody
                                                defCanType
                                                defTvar
                                                info
                                                stAcc
                                    in
                                    ( monoDef :: defsAcc, st1 )
                                )
                                ( [], statePopped )
                                instancesList

                        stateWithVars =
                            List.foldl
                                (\info st ->
                                    { st | varEnv = State.insertVar info.freshName info.monoType st.varEnv }
                                )
                                stateWithDefs
                                instancesList

                        -- Re-specialize body with instance names bound in VarEnv
                        ( monoBody2, stateAfterBody2 ) =
                            specializeExpr view snapshot body stateWithVars

                        finalExpr =
                            List.foldl
                                (\def_ accBody ->
                                    Mono.MonoLet def_ accBody (Mono.typeOf accBody)
                                )
                                monoBody2
                                instanceDefs
                    in
                    ( finalExpr, stateAfterBody2 )

            [] ->
                Utils.Crash.crash "MonoDirect.specializeLetTailDef: localMulti stack underflow"

    else
        -- Concrete type: single instance
        specializeLetTailDefSingle view snapshot defName defParams defBody defCanType defTvar funcMonoType0 body monoType state


specializeLetTailDefSingle :
    LocalView
    -> SolverSnapshot
    -> Name
    -> List ( A.Located Name, Can.Type )
    -> TOpt.Expr
    -> Can.Type
    -> Maybe SolverSnapshot.TypeVar
    -> Mono.MonoType
    -> TOpt.Expr
    -> Mono.MonoType
    -> MonoDirectState
    -> ( Mono.MonoExpr, MonoDirectState )
specializeLetTailDefSingle view snapshot defName defParams defBody defCanType defTvar funcMonoType body monoType state =
    let
        ( paramMonoTypes, _ ) =
            Closure.flattenFunctionType funcMonoType

        monoParams =
            List.map2
                (\( locName, _ ) paramType -> ( A.toValue locName, paramType ))
                defParams
                (padOrTruncate paramMonoTypes (List.length defParams))

        tailDefSubst =
            TypeSubst.unifyExtend defCanType funcMonoType Dict.empty

        tailDefInnerStack =
            case defTvar of
                Just tv ->
                    ( tv, funcMonoType ) :: state.specStack

                Nothing ->
                    state.specStack

        ( monoDefBody, stateAfterDef ) =
            SolverSnapshot.specializeChainedWithSubst snapshot
                tailDefInnerStack
                tailDefSubst
                (\innerView ->
                    let
                        st1 =
                            { state
                                | varEnv = State.pushFrame state.varEnv
                                , specStack = tailDefInnerStack
                            }

                        st2 =
                            List.foldl
                                (\( name, mt ) s -> { s | varEnv = State.insertVar name mt s.varEnv })
                                st1
                                monoParams

                        ( defBody_, st3 ) =
                            specializeExpr innerView snapshot defBody st2

                        st4 =
                            { st3
                                | varEnv = State.popFrame st3.varEnv
                                , specStack = state.specStack
                            }
                    in
                    ( defBody_, st4 )
                )

        stateWithVar =
            { stateAfterDef | varEnv = State.insertVar defName funcMonoType stateAfterDef.varEnv }

        ( monoBody, stateAfterAll ) =
            specializeExpr view snapshot body stateWithVar

        monoDef =
            Mono.MonoTailDef defName monoParams monoDefBody

        letResultType =
            if Mono.containsAnyMVar monoType then
                Mono.typeOf monoBody

            else
                monoType
    in
    ( Mono.MonoLet monoDef monoBody letResultType, stateAfterAll )


specializeTailDefForInstance :
    LocalView
    -> SolverSnapshot
    -> Name
    -> List ( A.Located Name, Can.Type )
    -> TOpt.Expr
    -> Can.Type
    -> Maybe SolverSnapshot.TypeVar
    -> State.LocalInstanceInfo
    -> MonoDirectState
    -> ( Mono.MonoDef, MonoDirectState )
specializeTailDefForInstance view snapshot defName defParams defBody defCanType defTvar info state =
    let
        funcSubst =
            TypeSubst.unifyExtend defCanType info.monoType Dict.empty

        innerStack =
            case defTvar of
                Just tvar ->
                    ( tvar, info.monoType ) :: state.specStack

                Nothing ->
                    state.specStack

        ( paramMonoTypes, _ ) =
            Closure.flattenFunctionType info.monoType

        monoParams =
            List.map2
                (\( locName, _ ) paramType -> ( A.toValue locName, paramType ))
                defParams
                (padOrTruncate paramMonoTypes (List.length defParams))
    in
    SolverSnapshot.specializeChainedWithSubst snapshot
        innerStack
        funcSubst
        (\innerView ->
            let
                st1 =
                    { state
                        | varEnv = State.pushFrame state.varEnv
                        , specStack = innerStack
                    }

                -- Insert defName so recursive self-references resolve to concrete type
                st1b =
                    { st1 | varEnv = State.insertVar defName info.monoType st1.varEnv }

                st2 =
                    List.foldl
                        (\( name, mt ) s -> { s | varEnv = State.insertVar name mt s.varEnv })
                        st1b
                        monoParams

                ( monoDefBody, st3 ) =
                    specializeExpr innerView snapshot defBody st2

                st4 =
                    { st3
                        | varEnv = State.popFrame st3.varEnv
                        , specStack = state.specStack
                    }

                renamedBody =
                    if info.freshName == defName then
                        monoDefBody

                    else
                        renameTailCalls defName info.freshName monoDefBody

                monoDef =
                    Mono.MonoTailDef info.freshName monoParams renamedBody
            in
            ( monoDef, st4 )
        )


{-| Rename tail-call targets in a MonoExpr from oldName to newName.
Used for multi-specialized TailDef clones.
-}
renameTailCalls : Name -> Name -> Mono.MonoExpr -> Mono.MonoExpr
renameTailCalls oldName newName expr =
    case expr of
        Mono.MonoTailCall name args resultType ->
            Mono.MonoTailCall
                (if name == oldName then
                    newName

                 else
                    name
                )
                (List.map (\( n, e ) -> ( n, renameTailCalls oldName newName e )) args)
                resultType

        Mono.MonoCall region func args resultType callInfo ->
            Mono.MonoCall region
                (renameTailCalls oldName newName func)
                (List.map (renameTailCalls oldName newName) args)
                resultType
                callInfo

        Mono.MonoIf branches final monoType ->
            Mono.MonoIf
                (List.map (\( c, t ) -> ( renameTailCalls oldName newName c, renameTailCalls oldName newName t )) branches)
                (renameTailCalls oldName newName final)
                monoType

        Mono.MonoLet def body resultType ->
            let
                newDef =
                    case def of
                        Mono.MonoDef n bound ->
                            Mono.MonoDef n (renameTailCalls oldName newName bound)

                        Mono.MonoTailDef n args bound ->
                            Mono.MonoTailDef n
                                args
                                (renameTailCalls oldName newName bound)
            in
            Mono.MonoLet newDef (renameTailCalls oldName newName body) resultType

        Mono.MonoClosure info body closureType ->
            Mono.MonoClosure info (renameTailCalls oldName newName body) closureType

        Mono.MonoList region items t ->
            Mono.MonoList region (List.map (renameTailCalls oldName newName) items) t

        Mono.MonoTupleCreate region items t ->
            Mono.MonoTupleCreate region (List.map (renameTailCalls oldName newName) items) t

        Mono.MonoRecordCreate fields t ->
            Mono.MonoRecordCreate
                (List.map (\( n, e ) -> ( n, renameTailCalls oldName newName e )) fields)
                t

        Mono.MonoRecordUpdate record updates t ->
            Mono.MonoRecordUpdate
                (renameTailCalls oldName newName record)
                (List.map (\( n, e ) -> ( n, renameTailCalls oldName newName e )) updates)
                t

        Mono.MonoRecordAccess record fieldName t ->
            Mono.MonoRecordAccess (renameTailCalls oldName newName record) fieldName t

        Mono.MonoDestruct destructor body t ->
            Mono.MonoDestruct destructor (renameTailCalls oldName newName body) t

        Mono.MonoCase scrutName typeName decider jumps monoType ->
            Mono.MonoCase scrutName
                typeName
                (renameTailCallsDecider oldName newName decider)
                (List.map (\( i, e ) -> ( i, renameTailCalls oldName newName e )) jumps)
                monoType

        _ ->
            expr


renameTailCallsDecider : Name -> Name -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice
renameTailCallsDecider oldName newName decider =
    case decider of
        Mono.Leaf choice ->
            Mono.Leaf (renameTailCallsChoice oldName newName choice)

        Mono.Chain conditions success failure ->
            Mono.Chain conditions
                (renameTailCallsDecider oldName newName success)
                (renameTailCallsDecider oldName newName failure)

        Mono.FanOut path edges fallback ->
            Mono.FanOut path
                (List.map (\( test, d ) -> ( test, renameTailCallsDecider oldName newName d )) edges)
                (renameTailCallsDecider oldName newName fallback)


renameTailCallsChoice : Name -> Name -> Mono.MonoChoice -> Mono.MonoChoice
renameTailCallsChoice oldName newName choice =
    case choice of
        Mono.Inline e ->
            Mono.Inline (renameTailCalls oldName newName e)

        Mono.Jump i ->
            Mono.Jump i


specializeLetFuncDef :
    LocalView
    -> SolverSnapshot
    -> Name
    -> TOpt.Expr
    -> TOpt.Expr
    -> Mono.MonoType
    -> MonoDirectState
    -> ( Mono.MonoExpr, MonoDirectState )
specializeLetFuncDef view snapshot defName defExpr body monoType state =
    let
        -- Push a local-multi tracking entry for this def
        newEntry =
            { defName = defName, instances = Dict.empty }

        stateForBody =
            { state | localMulti = newEntry :: state.localMulti }

        -- Specialize body first to discover call-site instances
        ( _, stateAfterBody ) =
            specializeExpr view snapshot body stateForBody
    in
    case stateAfterBody.localMulti of
        topEntry :: restOfStack ->
            if Dict.isEmpty topEntry.instances then
                -- No calls recorded: single-instance fallback
                let
                    ( monoDefExpr, state1 ) =
                        specializeExpr view
                            snapshot
                            defExpr
                            { stateAfterBody | localMulti = restOfStack }

                    defMonoType =
                        Mono.typeOf monoDefExpr

                    state2 =
                        { state1 | varEnv = State.insertVar defName defMonoType state1.varEnv }

                    -- Re-specialize body with defName bound
                    ( monoBody2, state3 ) =
                        specializeExpr view snapshot body state2

                    monoDef =
                        Mono.MonoDef defName monoDefExpr

                    letResultType =
                        if Mono.containsAnyMVar monoType then
                            Mono.typeOf monoBody2

                        else
                            monoType
                in
                ( Mono.MonoLet monoDef monoBody2 letResultType, state3 )

            else
                -- Multiple instances discovered from call sites
                let
                    instancesList =
                        Dict.values topEntry.instances
                            |> List.sortBy (\info -> Mono.monoTypeToDebugString info.monoType)

                    statePopped =
                        { stateAfterBody | localMulti = restOfStack }

                    -- For each instance: re-specialize defExpr with param types from instance.monoType
                    ( instanceDefs, stateWithDefs ) =
                        List.foldl
                            (\info ( defsAcc, stAcc ) ->
                                let
                                    ( monoDef, st1 ) =
                                        specializeDefForInstance view
                                            snapshot
                                            defName
                                            defExpr
                                            info
                                            stAcc
                                in
                                ( monoDef :: defsAcc, st1 )
                            )
                            ( [], statePopped )
                            instancesList

                    -- Register all instance names in VarEnv
                    stateWithVars =
                        List.foldl
                            (\info st ->
                                { st | varEnv = State.insertVar info.freshName info.monoType st.varEnv }
                            )
                            stateWithDefs
                            instancesList

                    -- Re-specialize body with instance names bound in VarEnv
                    ( monoBody2, stateAfterBody2 ) =
                        specializeExpr view snapshot body stateWithVars

                    finalExpr =
                        List.foldl
                            (\def_ accBody ->
                                Mono.MonoLet def_ accBody (Mono.typeOf accBody)
                            )
                            monoBody2
                            instanceDefs
                in
                ( finalExpr, stateAfterBody2 )

        [] ->
            Utils.Crash.crash
                "MonoDirect.specializeLetFuncDef: localMulti stack underflow"


specializeDefForInstance :
    LocalView
    -> SolverSnapshot
    -> Name
    -> TOpt.Expr
    -> State.LocalInstanceInfo
    -> MonoDirectState
    -> ( Mono.MonoDef, MonoDirectState )
specializeDefForInstance view snapshot defName defExpr info state =
    let
        ( paramTypes, _ ) =
            Closure.flattenFunctionType info.monoType
    in
    case defExpr of
        TOpt.Function params bodyExpr funcMeta ->
            case funcMeta.tvar of
                Just tvar ->
                    let
                        innerStack =
                            ( tvar, info.monoType ) :: state.specStack

                        funcSubstF =
                            TypeSubst.unifyExtend funcMeta.tipe info.monoType Dict.empty
                    in
                    SolverSnapshot.specializeChainedWithSubst snapshot
                        innerStack
                        funcSubstF
                        (\innerView ->
                            let
                                monoParams =
                                    List.map2
                                        (\( name, _ ) pt -> ( name, pt ))
                                        params
                                        (padOrTruncate paramTypes (List.length params))

                                state1 =
                                    { state
                                        | varEnv = State.pushFrame state.varEnv
                                        , specStack = innerStack
                                    }

                                -- Insert defName so recursive self-references resolve to concrete type
                                state1b =
                                    { state1 | varEnv = State.insertVar defName info.monoType state1.varEnv }

                                state2 =
                                    List.foldl
                                        (\( n, t ) s -> { s | varEnv = State.insertVar n t s.varEnv })
                                        state1b
                                        monoParams

                                ( monoBody, state3 ) =
                                    specializeExpr innerView snapshot bodyExpr state2

                                state4 =
                                    { state3
                                        | varEnv = State.popFrame state3.varEnv
                                        , specStack = state.specStack
                                    }

                                captures =
                                    Closure.computeClosureCaptures monoParams monoBody

                                closureExpr =
                                    Mono.MonoClosure
                                        { lambdaId = Mono.AnonymousLambda state.currentModule state.lambdaCounter
                                        , captures = captures
                                        , params = monoParams
                                        , closureKind = Nothing
                                        , captureAbi = Nothing
                                        }
                                        monoBody
                                        info.monoType
                            in
                            ( Mono.MonoDef info.freshName closureExpr
                            , { state4 | lambdaCounter = state4.lambdaCounter + 1 }
                            )
                        )

                Nothing ->
                    let
                        funcSubstF =
                            TypeSubst.unifyExtend funcMeta.tipe info.monoType Dict.empty
                    in
                    SolverSnapshot.specializeChainedWithSubst snapshot
                        state.specStack
                        funcSubstF
                        (\innerView ->
                            let
                                monoParams =
                                    List.map2
                                        (\( name, _ ) pt -> ( name, pt ))
                                        params
                                        (padOrTruncate paramTypes (List.length params))

                                state1 =
                                    { state | varEnv = State.pushFrame state.varEnv }

                                -- Insert defName so recursive self-references resolve to concrete type
                                state1b =
                                    { state1 | varEnv = State.insertVar defName info.monoType state1.varEnv }

                                state2 =
                                    List.foldl
                                        (\( n, t ) s -> { s | varEnv = State.insertVar n t s.varEnv })
                                        state1b
                                        monoParams

                                ( monoBody, state3 ) =
                                    specializeExpr innerView snapshot bodyExpr state2

                                state4 =
                                    { state3 | varEnv = State.popFrame state3.varEnv }

                                captures =
                                    Closure.computeClosureCaptures monoParams monoBody

                                closureExpr =
                                    Mono.MonoClosure
                                        { lambdaId = Mono.AnonymousLambda state.currentModule state.lambdaCounter
                                        , captures = captures
                                        , params = monoParams
                                        , closureKind = Nothing
                                        , captureAbi = Nothing
                                        }
                                        monoBody
                                        info.monoType
                            in
                            ( Mono.MonoDef info.freshName closureExpr
                            , { state4 | lambdaCounter = state4.lambdaCounter + 1 }
                            )
                        )

        TOpt.TrackedFunction params bodyExpr funcMeta ->
            let
                unlocatedParams =
                    List.map (\( A.At _ name, tipe ) -> ( name, tipe )) params

                funcSubst =
                    TypeSubst.unifyExtend funcMeta.tipe info.monoType Dict.empty

                innerStack =
                    case funcMeta.tvar of
                        Just tvar ->
                            ( tvar, info.monoType ) :: state.specStack

                        Nothing ->
                            state.specStack
            in
            SolverSnapshot.specializeChainedWithSubst snapshot
                innerStack
                funcSubst
                (\innerView ->
                    let
                        monoParams =
                            List.map2
                                (\( name, _ ) pt -> ( name, pt ))
                                unlocatedParams
                                (padOrTruncate paramTypes (List.length unlocatedParams))

                        state1 =
                            { state
                                | varEnv = State.pushFrame state.varEnv
                                , specStack = innerStack
                            }

                        -- Insert defName so recursive self-references resolve to concrete type
                        state1b =
                            { state1 | varEnv = State.insertVar defName info.monoType state1.varEnv }

                        state2 =
                            List.foldl
                                (\( n, t ) s -> { s | varEnv = State.insertVar n t s.varEnv })
                                state1b
                                monoParams

                        ( monoBody, state3 ) =
                            specializeExpr innerView snapshot bodyExpr state2

                        state4 =
                            { state3
                                | varEnv = State.popFrame state3.varEnv
                                , specStack = state.specStack
                            }

                        captures =
                            Closure.computeClosureCaptures monoParams monoBody

                        closureExpr =
                            Mono.MonoClosure
                                { lambdaId = Mono.AnonymousLambda state.currentModule state.lambdaCounter
                                , captures = captures
                                , params = monoParams
                                , closureKind = Nothing
                                , captureAbi = Nothing
                                }
                                monoBody
                                info.monoType
                    in
                    ( Mono.MonoDef info.freshName closureExpr
                    , { state4 | lambdaCounter = state4.lambdaCounter + 1 }
                    )
                )

        _ ->
            -- Non-function def (e.g. mapId = map (\s -> s)): update view's subst
            -- with bindings derived from expression type vs requested mono type.
            let
                defSubst =
                    TypeSubst.unifyExtend (TOpt.typeOf defExpr) info.monoType view.subst

                innerView =
                    { view | subst = defSubst }

                ( monoExpr, state1 ) =
                    specializeExpr innerView snapshot defExpr state
            in
            ( Mono.MonoDef info.freshName monoExpr, state1 )



-- ========== CYCLE SPECIALIZATION ==========


specializeCycle : SolverSnapshot -> List Name -> List ( Name, TOpt.Expr ) -> List TOpt.Def -> Mono.MonoType -> MonoDirectState -> ( Mono.MonoNode, MonoDirectState )
specializeCycle snapshot names valueDefs funcDefs requestedMonoType state =
    case funcDefs of
        [] ->
            -- Value-only cycle: existing behavior
            SolverSnapshot.withLocalUnification snapshot
                []
                []
                (\view ->
                    let
                        ( monoValueDefs, state1 ) =
                            List.foldl
                                (\( name, expr ) ( acc, s ) ->
                                    let
                                        ( monoExpr, s1 ) =
                                            specializeExpr view snapshot expr s
                                    in
                                    ( acc ++ [ ( name, monoExpr ) ], s1 )
                                )
                                ( [], state )
                                valueDefs
                    in
                    ( Mono.MonoCycle monoValueDefs requestedMonoType, state1 )
                )

        _ ->
            -- Function cycle: emit separate MonoNodes per function via registry
            case state.currentGlobal of
                Nothing ->
                    ( Mono.MonoExtern requestedMonoType, state )

                Just (Mono.Accessor _) ->
                    ( Mono.MonoExtern requestedMonoType, state )

                Just (Mono.Global requestedCanonical requestedName) ->
                    let
                        requestedTvar =
                            List.filterMap
                                (\funcDef ->
                                    let
                                        ( name, _, tvar ) =
                                            funcDefInfo funcDef
                                    in
                                    if name == requestedName then
                                        tvar

                                    else
                                        Nothing
                                )
                                funcDefs
                                |> List.head

                        cycleStack =
                            case requestedTvar of
                                Just tvar ->
                                    ( tvar, requestedMonoType ) :: state.specStack

                                Nothing ->
                                    state.specStack
                    in
                    SolverSnapshot.specializeChained snapshot
                        cycleStack
                        (\view ->
                            let
                                -- Pre-bind all function names in VarEnv for mutual recursion
                                stateWithBindings =
                                    List.foldl
                                        (\funcDef s ->
                                            let
                                                ( defName, defCanType, defTvar ) =
                                                    funcDefInfo funcDef

                                                funcMonoType =
                                                    resolveType view { tipe = defCanType, tvar = defTvar }
                                            in
                                            { s | varEnv = State.insertVar defName funcMonoType s.varEnv }
                                        )
                                        { state | specStack = cycleStack }
                                        funcDefs

                                -- Specialize each function def and insert into nodes dict
                                ( newNodes, stateAfterFuncs ) =
                                    List.foldl
                                        (\funcDef ( nodesAcc, s ) ->
                                            let
                                                ( defName, defCanType, defTvar ) =
                                                    funcDefInfo funcDef

                                                funcMonoType =
                                                    resolveType view { tipe = defCanType, tvar = defTvar }

                                                monoTypeForSpec =
                                                    if defName == requestedName then
                                                        requestedMonoType

                                                    else
                                                        funcMonoType

                                                monoGlobal =
                                                    Mono.Global requestedCanonical defName

                                                ( specId, s1 ) =
                                                    enqueueSpec monoGlobal monoTypeForSpec Nothing s

                                                ( node, s2 ) =
                                                    specializeFuncDefInCycle view snapshot funcDef s1
                                            in
                                            ( Dict.insert specId node nodesAcc, s2 )
                                        )
                                        ( stateWithBindings.nodes, stateWithBindings )
                                        funcDefs

                                -- Look up the requested function's node
                                ( requestedSpecId, registryAfter ) =
                                    Registry.getOrCreateSpecId
                                        (Mono.Global requestedCanonical requestedName)
                                        requestedMonoType
                                        Nothing
                                        stateAfterFuncs.registry
                            in
                            case Dict.get requestedSpecId newNodes of
                                Just requestedNode ->
                                    ( requestedNode
                                    , { stateAfterFuncs
                                        | nodes = newNodes
                                        , registry = registryAfter
                                        , specStack = state.specStack
                                      }
                                    )

                                Nothing ->
                                    ( Mono.MonoExtern requestedMonoType
                                    , { stateAfterFuncs
                                        | nodes = newNodes
                                        , registry = registryAfter
                                        , specStack = state.specStack
                                      }
                                    )
                        )


funcDefInfo : TOpt.Def -> ( Name, Can.Type, Maybe IO.Variable )
funcDefInfo def =
    case def of
        TOpt.Def _ name _ canType ->
            ( name, canType, Nothing )

        TOpt.TailDef _ name _ _ canType tvar ->
            ( name, canType, tvar )


specializeFuncDefInCycle :
    LocalView
    -> SolverSnapshot
    -> TOpt.Def
    -> MonoDirectState
    -> ( Mono.MonoNode, MonoDirectState )
specializeFuncDefInCycle view snapshot funcDef state =
    case funcDef of
        TOpt.TailDef _ _ defParams defBody defCanType defTvar ->
            let
                funcMonoType =
                    resolveType view { tipe = defCanType, tvar = defTvar }

                ( paramMonoTypes, _ ) =
                    Closure.flattenFunctionType funcMonoType

                monoParams =
                    List.map2
                        (\( locName, _ ) paramType -> ( A.toValue locName, paramType ))
                        defParams
                        (padOrTruncate paramMonoTypes (List.length defParams))

                state1 =
                    { state | varEnv = State.pushFrame state.varEnv }

                state2 =
                    List.foldl
                        (\( name, mt ) s -> { s | varEnv = State.insertVar name mt s.varEnv })
                        state1
                        monoParams

                ( monoBody, state3 ) =
                    specializeExpr view snapshot defBody state2

                state4 =
                    { state3 | varEnv = State.popFrame state3.varEnv }
            in
            ( Mono.MonoTailFunc monoParams monoBody funcMonoType, state4 )

        TOpt.Def _ _ defExpr _ ->
            let
                ( monoExpr, state1 ) =
                    specializeExpr view snapshot defExpr state
            in
            ( Mono.MonoDefine monoExpr (Mono.typeOf monoExpr), state1 )



-- ========== HELPERS ==========


specializeExprs : LocalView -> SolverSnapshot -> List TOpt.Expr -> MonoDirectState -> ( List Mono.MonoExpr, MonoDirectState )
specializeExprs view snapshot exprs state =
    List.foldl
        (\expr ( acc, s ) ->
            let
                ( monoExpr, s1 ) =
                    specializeExpr view snapshot expr s
            in
            ( acc ++ [ monoExpr ], s1 )
        )
        ( [], state )
        exprs


specializeNamedExprs : LocalView -> SolverSnapshot -> List ( Name, TOpt.Expr ) -> MonoDirectState -> ( List ( Name, Mono.MonoExpr ), MonoDirectState )
specializeNamedExprs view snapshot namedExprs state =
    List.foldl
        (\( name, expr ) ( acc, s ) ->
            let
                ( monoExpr, s1 ) =
                    specializeExpr view snapshot expr s
            in
            ( acc ++ [ ( name, monoExpr ) ], s1 )
        )
        ( [], state )
        namedExprs


specializeFieldExprs : LocalView -> SolverSnapshot -> Dict Name TOpt.Expr -> MonoDirectState -> ( List ( Name, Mono.MonoExpr ), MonoDirectState )
specializeFieldExprs view snapshot fields state =
    Dict.foldl
        (\name expr ( acc, s ) ->
            let
                ( monoExpr, s1 ) =
                    specializeExpr view snapshot expr s
            in
            ( acc ++ [ ( name, monoExpr ) ], s1 )
        )
        ( [], state )
        fields


specializeLocatedFieldExprs : LocalView -> SolverSnapshot -> DMap.Dict String (A.Located Name) TOpt.Expr -> MonoDirectState -> ( List ( Name, Mono.MonoExpr ), MonoDirectState )
specializeLocatedFieldExprs view snapshot fields state =
    DMap.foldl A.compareLocated
        (\(A.At _ name) expr ( acc, s ) ->
            let
                ( monoExpr, s1 ) =
                    specializeExpr view snapshot expr s
            in
            ( acc ++ [ ( name, monoExpr ) ], s1 )
        )
        ( [], state )
        fields


specializeBranches : LocalView -> SolverSnapshot -> List ( TOpt.Expr, TOpt.Expr ) -> MonoDirectState -> ( List ( Mono.MonoExpr, Mono.MonoExpr ), MonoDirectState )
specializeBranches view snapshot branches state0 =
    let
        savedVarEnv =
            state0.varEnv
    in
    List.foldl
        (\( cond, thenExpr ) ( acc, s ) ->
            let
                sWithReset =
                    { s | varEnv = savedVarEnv }

                ( monoCond, s1 ) =
                    specializeExpr view snapshot cond sWithReset

                ( monoThen, s2 ) =
                    specializeExpr view snapshot thenExpr s1
            in
            ( acc ++ [ ( monoCond, monoThen ) ], s2 )
        )
        ( [], state0 )
        branches


{-| Convert a TypedPath.ContainerHint to a ContainerKind for MonoDtPath.
-}
dtHintToKind : TypedPath.ContainerHint -> Mono.ContainerKind
dtHintToKind hint =
    case hint of
        TypedPath.HintList ->
            Mono.ListContainer

        TypedPath.HintTuple2 ->
            Mono.Tuple2Container

        TypedPath.HintTuple3 ->
            Mono.Tuple3Container

        TypedPath.HintCustom ctorName ->
            Mono.CustomContainer ctorName

        TypedPath.HintUnknown ->
            Mono.CustomContainer ""


{-| Convert TypedPath.ContainerHint to TOpt.ContainerHint for reuse of computeIndexProjectionType.
-}
dtHintToTOptHint : TypedPath.ContainerHint -> TOpt.ContainerHint
dtHintToTOptHint hint =
    case hint of
        TypedPath.HintList ->
            TOpt.HintList

        TypedPath.HintTuple2 ->
            TOpt.HintTuple2

        TypedPath.HintTuple3 ->
            TOpt.HintTuple3

        TypedPath.HintCustom ctorName ->
            TOpt.HintCustom ctorName

        TypedPath.HintUnknown ->
            TOpt.HintCustom ""


{-| Convert a DT.Path (TypedPath) to a MonoDtPath by resolving types from VarEnv.
-}
specializeDtPath : Name -> TypedPath.Path -> VarEnv -> TypeEnv.GlobalTypeEnv -> Mono.MonoDtPath
specializeDtPath rootName dtPath varEnv globalTypeEnv =
    let
        rootType =
            case State.lookupVar rootName varEnv of
                Just ty ->
                    ty

                Nothing ->
                    Utils.Crash.crash ("MonoDirect.specializeDtPath: Root '" ++ rootName ++ "' not in VarEnv")

        go : TypedPath.Path -> Mono.MonoDtPath
        go path =
            case path of
                TypedPath.Empty ->
                    Mono.DtRoot rootName rootType

                TypedPath.Index index hint subPath ->
                    let
                        monoSubPath =
                            go subPath

                        containerType =
                            Mono.dtPathType monoSubPath

                        resultType =
                            computeIndexProjectionType globalTypeEnv (dtHintToTOptHint hint) (Index.toMachine index) containerType
                    in
                    Mono.DtIndex (Index.toMachine index) (dtHintToKind hint) resultType monoSubPath

                TypedPath.Unbox subPath ->
                    let
                        monoSubPath =
                            go subPath

                        containerType =
                            Mono.dtPathType monoSubPath

                        resultType =
                            computeUnboxResultType globalTypeEnv containerType
                    in
                    Mono.DtUnbox resultType monoSubPath
    in
    go dtPath


specializeDecider : Name -> LocalView -> SolverSnapshot -> TOpt.Decider TOpt.Choice -> MonoDirectState -> ( Mono.Decider Mono.MonoChoice, MonoDirectState )
specializeDecider rootName view snapshot decider state =
    case decider of
        TOpt.Leaf (TOpt.Inline expr) ->
            let
                ( monoExpr, state1 ) =
                    specializeExpr view snapshot expr state
            in
            ( Mono.Leaf (Mono.Inline monoExpr), state1 )

        TOpt.Leaf (TOpt.Jump i) ->
            ( Mono.Leaf (Mono.Jump i), state )

        TOpt.Chain testChain success failure ->
            let
                savedVarEnv =
                    state.varEnv

                monoTestChain =
                    List.map
                        (\( path, test ) ->
                            ( specializeDtPath rootName path state.varEnv state.globalTypeEnv, test )
                        )
                        testChain

                ( monoSuccess, state1 ) =
                    specializeDecider rootName view snapshot success state

                state1WithResetVarEnv =
                    { state1 | varEnv = savedVarEnv }

                ( monoFailure, state2 ) =
                    specializeDecider rootName view snapshot failure state1WithResetVarEnv
            in
            ( Mono.Chain monoTestChain monoSuccess monoFailure, state2 )

        TOpt.FanOut path tests fallback ->
            let
                savedVarEnv =
                    state.varEnv

                monoPath =
                    specializeDtPath rootName path state.varEnv state.globalTypeEnv

                ( monoTests, state1 ) =
                    List.foldr
                        (\( test, subDecider ) ( acc, s ) ->
                            let
                                sWithResetVarEnv =
                                    { s | varEnv = savedVarEnv }

                                ( monoSubDecider, s1 ) =
                                    specializeDecider rootName view snapshot subDecider sWithResetVarEnv
                            in
                            ( ( test, monoSubDecider ) :: acc, s1 )
                        )
                        ( [], state )
                        tests

                state1WithResetVarEnv =
                    { state1 | varEnv = savedVarEnv }

                ( monoFallback, state2 ) =
                    specializeDecider rootName view snapshot fallback state1WithResetVarEnv
            in
            ( Mono.FanOut monoPath monoTests monoFallback, state2 )


specializeJumps : LocalView -> SolverSnapshot -> List ( Int, TOpt.Expr ) -> MonoDirectState -> ( List ( Int, Mono.MonoExpr ), MonoDirectState )
specializeJumps view snapshot jumps state =
    let
        savedVarEnv =
            state.varEnv
    in
    List.foldr
        (\( idx, expr ) ( acc, s ) ->
            let
                sWithResetVarEnv =
                    { s | varEnv = savedVarEnv }

                ( monoExpr, s1 ) =
                    specializeExpr view snapshot expr sWithResetVarEnv
            in
            ( ( idx, monoExpr ) :: acc, s1 )
        )
        ( [], state )
        jumps


specializeDestructor : LocalView -> VarEnv -> TypeEnv.GlobalTypeEnv -> TOpt.Destructor -> Mono.MonoDestructor
specializeDestructor view varEnv globalTypeEnv (TOpt.Destructor name path meta) =
    let
        monoPath =
            specializePath view varEnv globalTypeEnv path

        -- Use path-derived type: the MonoPath already computes the correct
        -- type by navigating from the root variable's resolved type.
        -- This is essential for record field destructors (PRecord) which
        -- have tvar=Nothing and can't use solver-based resolution.
        monoType =
            Mono.getMonoPathType monoPath
    in
    Mono.MonoDestructor name monoPath monoType


specializePath : LocalView -> VarEnv -> TypeEnv.GlobalTypeEnv -> TOpt.Path -> Mono.MonoPath
specializePath view varEnv globalTypeEnv path =
    case path of
        TOpt.Index index hint inner ->
            let
                monoSubPath =
                    specializePath view varEnv globalTypeEnv inner

                containerType =
                    Mono.getMonoPathType monoSubPath

                resultType =
                    computeIndexProjectionType globalTypeEnv hint (Index.toMachine index) containerType
            in
            Mono.MonoIndex (Index.toMachine index) (hintToKind hint) resultType monoSubPath

        TOpt.ArrayIndex idx inner ->
            let
                monoSubPath =
                    specializePath view varEnv globalTypeEnv inner

                containerType =
                    Mono.getMonoPathType monoSubPath

                resultType =
                    computeArrayElementType containerType
            in
            Mono.MonoIndex idx (Mono.CustomContainer "") resultType monoSubPath

        TOpt.Field fieldName inner ->
            let
                monoSubPath =
                    specializePath view varEnv globalTypeEnv inner

                recordType =
                    Mono.getMonoPathType monoSubPath

                resultType =
                    case recordType of
                        Mono.MRecord fields ->
                            case Dict.get fieldName fields of
                                Just fieldMonoType ->
                                    fieldMonoType

                                Nothing ->
                                    Utils.Crash.crash
                                        ("MonoDirect.specializePath: Field '"
                                            ++ fieldName
                                            ++ "' not found in record type."
                                        )

                        _ ->
                            Utils.Crash.crash
                                ("MonoDirect.specializePath: Expected MRecord for field path but got: "
                                    ++ Mono.monoTypeToDebugString recordType
                                )
            in
            Mono.MonoField fieldName resultType monoSubPath

        TOpt.Unbox inner ->
            let
                monoSubPath =
                    specializePath view varEnv globalTypeEnv inner

                containerType =
                    Mono.getMonoPathType monoSubPath

                resultType =
                    computeUnboxResultType globalTypeEnv containerType
            in
            Mono.MonoUnbox resultType monoSubPath

        TOpt.Root name ->
            let
                rootType =
                    case State.lookupVar name varEnv of
                        Just ty ->
                            ty

                        Nothing ->
                            Utils.Crash.crash ("MonoDirect.specializePath: Root variable '" ++ name ++ "' not found in VarEnv.")
            in
            Mono.MonoRoot name rootType


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


{-| Compute the result type of projecting at an index from a container.
-}
computeIndexProjectionType : TypeEnv.GlobalTypeEnv -> TOpt.ContainerHint -> Int -> Mono.MonoType -> Mono.MonoType
computeIndexProjectionType globalTypeEnv hint index containerType =
    case hint of
        TOpt.HintList ->
            case containerType of
                Mono.MList elemType ->
                    if index == 0 then
                        elemType

                    else
                        containerType

                _ ->
                    Utils.Crash.crash ("MonoDirect.computeIndexProjectionType: HintList at index " ++ String.fromInt index ++ " - Expected MList but got: " ++ Mono.monoTypeToDebugString containerType)

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
                    Utils.Crash.crash ("MonoDirect.computeTupleElementType: Tuple index " ++ String.fromInt index ++ " out of bounds for tuple with " ++ String.fromInt (List.length elementTypes) ++ " elements")

        _ ->
            Utils.Crash.crash ("MonoDirect.computeTupleElementType: Expected MTuple but got: " ++ Mono.monoTypeToDebugString containerType)


{-| Compute field type from a custom type constructor at the given index.
-}
computeCustomFieldType : TypeEnv.GlobalTypeEnv -> Name -> Int -> Mono.MonoType -> Mono.MonoType
computeCustomFieldType globalTypeEnv ctorName index containerType =
    case containerType of
        Mono.MCustom moduleName typeName typeArgs ->
            case Analysis.lookupUnion globalTypeEnv moduleName typeName of
                Nothing ->
                    Utils.Crash.crash ("MonoDirect.computeCustomFieldType: Union not found: " ++ typeName)

                Just (Can.Union unionData) ->
                    case findCtorByName ctorName unionData.alts of
                        Nothing ->
                            Utils.Crash.crash ("MonoDirect.computeCustomFieldType: Constructor '" ++ ctorName ++ "' not found in union " ++ typeName)

                        Just (Can.Ctor ctorData) ->
                            case List.drop index ctorData.args of
                                canArgType :: _ ->
                                    let
                                        typeVarSubst =
                                            Dict.fromList (List.map2 Tuple.pair unionData.vars typeArgs)
                                    in
                                    Mono.forceCNumberToInt (TypeSubst.applySubst typeVarSubst canArgType)

                                [] ->
                                    Utils.Crash.crash ("MonoDirect.computeCustomFieldType: Constructor arg index " ++ String.fromInt index ++ " out of bounds for " ++ ctorName)

        _ ->
            Utils.Crash.crash ("MonoDirect.computeCustomFieldType: Expected MCustom for ctor '" ++ ctorName ++ "' index " ++ String.fromInt index ++ " but got: " ++ Mono.monoTypeToDebugString containerType)


{-| Find a constructor by name in a list of alternatives.
-}
findCtorByName : Name -> List Can.Ctor -> Maybe Can.Ctor
findCtorByName targetName alts =
    List.filter (\(Can.Ctor ctorData) -> ctorData.name == targetName) alts
        |> List.head


{-| Compute the result type of unwrapping a single-constructor type.
-}
computeUnboxResultType : TypeEnv.GlobalTypeEnv -> Mono.MonoType -> Mono.MonoType
computeUnboxResultType globalTypeEnv containerType =
    case containerType of
        Mono.MCustom moduleName typeName typeArgs ->
            case Analysis.lookupUnion globalTypeEnv moduleName typeName of
                Nothing ->
                    Utils.Crash.crash ("MonoDirect.computeUnboxResultType: Union not found: " ++ typeName)

                Just (Can.Union unionData) ->
                    case unionData.alts of
                        [ Can.Ctor ctorData ] ->
                            case ctorData.args of
                                [ canArgType ] ->
                                    let
                                        typeVarSubst =
                                            Dict.fromList (List.map2 Tuple.pair unionData.vars typeArgs)
                                    in
                                    Mono.forceCNumberToInt (TypeSubst.applySubst typeVarSubst canArgType)

                                _ ->
                                    Utils.Crash.crash ("MonoDirect.computeUnboxResultType: Expected single-arg constructor but got " ++ String.fromInt (List.length ctorData.args) ++ " args for " ++ typeName)

                        _ ->
                            Utils.Crash.crash ("MonoDirect.computeUnboxResultType: Expected single-constructor type but got " ++ String.fromInt (List.length unionData.alts) ++ " constructors for " ++ typeName)

        _ ->
            Utils.Crash.crash ("MonoDirect.computeUnboxResultType: Expected MCustom but got: " ++ Mono.monoTypeToDebugString containerType)


{-| Compute element type from an array access.
-}
computeArrayElementType : Mono.MonoType -> Mono.MonoType
computeArrayElementType containerType =
    case containerType of
        Mono.MCustom _ "Array" [ elemType ] ->
            elemType

        _ ->
            Utils.Crash.crash ("MonoDirect.computeArrayElementType: Expected Array type but got: " ++ Mono.monoTypeToDebugString containerType)



-- ========== CECO REFINEMENT HELPERS ==========


inferCaseType :
    List ( Int, Mono.MonoExpr )
    -> Mono.Decider Mono.MonoChoice
    -> Mono.MonoType
    -> Mono.MonoType
inferCaseType jumps decider fallback =
    case jumps of
        ( _, expr ) :: _ ->
            Mono.typeOf expr

        [] ->
            case firstLeafType decider of
                Just t ->
                    t

                Nothing ->
                    fallback


firstLeafType : Mono.Decider Mono.MonoChoice -> Maybe Mono.MonoType
firstLeafType decider =
    case decider of
        Mono.Leaf (Mono.Inline expr) ->
            Just (Mono.typeOf expr)

        Mono.Chain _ success _ ->
            firstLeafType success

        Mono.FanOut _ tests _ ->
            case tests of
                ( _, sub ) :: _ ->
                    firstLeafType sub

                [] ->
                    Nothing

        _ ->
            Nothing



-- ========== KERNEL ABI ==========


deriveKernelAbiTypeDirect : ( String, String ) -> TOpt.Meta -> LocalView -> Mono.MonoType
deriveKernelAbiTypeDirect ( home, name ) meta view =
    let
        -- Use meta.tipe for ABI mode detection (avoids variableToCanType Error crashes)
        canType =
            meta.tipe

        monoType =
            case meta.tvar of
                Just tvar ->
                    Mono.forceCNumberToInt (view.monoTypeOf tvar)

                Nothing ->
                    Mono.forceCNumberToInt (TypeSubst.applySubst view.subst canType)

        mode =
            KernelAbi.deriveKernelAbiMode ( home, name ) canType

        isFullyMono =
            isFullyMonomorphicType monoType
    in
    case mode of
        KernelAbi.UseSubstitution ->
            monoType

        KernelAbi.NumberBoxed ->
            if isFullyMono then
                monoType

            else
                KernelAbi.canTypeToMonoType_preserveVars canType

        KernelAbi.PreserveVars ->
            if isFullyMono then
                monoType

            else
                KernelAbi.canTypeToMonoType_preserveVars canType


isFullyMonomorphicType : Mono.MonoType -> Bool
isFullyMonomorphicType monoType =
    case monoType of
        Mono.MVar _ _ ->
            False

        Mono.MList elem ->
            isFullyMonomorphicType elem

        Mono.MFunction args result ->
            List.all isFullyMonomorphicType args && isFullyMonomorphicType result

        Mono.MTuple elems ->
            List.all isFullyMonomorphicType elems

        Mono.MRecord fields ->
            Dict.foldl (\_ t acc -> acc && isFullyMonomorphicType t) True fields

        Mono.MCustom _ _ args ->
            List.all isFullyMonomorphicType args

        _ ->
            True


{-| Check if a Can.Type contains no type variables (is fully monomorphic).
Used to distinguish truly monomorphic synthetic nodes from polymorphic ones
that are missing solver variables (which is a bug).
-}
isMonomorphicCanType : Can.Type -> Bool
isMonomorphicCanType tipe =
    case tipe of
        Can.TVar _ ->
            False

        Can.TLambda a b ->
            isMonomorphicCanType a && isMonomorphicCanType b

        Can.TType _ _ args ->
            List.all isMonomorphicCanType args

        Can.TTuple a b rest ->
            isMonomorphicCanType a
                && isMonomorphicCanType b
                && List.all isMonomorphicCanType rest

        Can.TRecord fields ext ->
            (ext == Nothing)
                && Dict.foldl (\_ (Can.FieldType _ t) ok -> ok && isMonomorphicCanType t) True fields

        Can.TAlias _ _ args _ ->
            List.all (\( _, t ) -> isMonomorphicCanType t) args

        Can.TUnit ->
            True



-- ========== UTILITY ==========


extractCtorResultType : Int -> Mono.MonoType -> Mono.MonoType
extractCtorResultType arity monoType =
    if arity <= 0 then
        monoType

    else
        case monoType of
            Mono.MFunction args result ->
                extractCtorResultType (arity - List.length args) result

            _ ->
                monoType


toptGlobalToMono : TOpt.Global -> Mono.Global
toptGlobalToMono (TOpt.Global canonical name) =
    Mono.Global canonical name


enqueueSpec : Mono.Global -> Mono.MonoType -> Maybe Mono.LambdaId -> MonoDirectState -> ( Mono.SpecId, MonoDirectState )
enqueueSpec global monoType maybeLambda state =
    let
        ( specId, newRegistry ) =
            Registry.getOrCreateSpecId global monoType maybeLambda state.registry
    in
    if BitSet.member specId state.scheduled then
        ( specId, { state | registry = newRegistry } )

    else
        ( specId
        , { state
            | registry = newRegistry
            , scheduled = BitSet.insertGrowing specId state.scheduled
            , worklist = State.SpecializeGlobal specId :: state.worklist
          }
        )


buildCtorShapeFromArity : Name -> Int -> Int -> Mono.MonoType -> Mono.CtorShape
buildCtorShapeFromArity name tag arity ctorMonoType =
    { name = name
    , tag = tag
    , fieldTypes = extractFieldTypes arity ctorMonoType
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


padOrTruncate : List a -> Int -> List a
padOrTruncate list targetLen =
    let
        len =
            List.length list
    in
    if len >= targetLen then
        List.take targetLen list

    else
        list
