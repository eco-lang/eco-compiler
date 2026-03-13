module Compiler.MonoDirect.Specialize exposing (specializeNode)

{-| Solver-directed expression specialization for MonoDirect.

Uses the solver snapshot for type resolution instead of TypeSubst
string-based substitution. Every expression's type is resolved through
the solver's union-find via LocalView.monoTypeOf.

@docs specializeNode

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.BitSet as BitSet
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.MonoDirect.State as State exposing (MonoDirectState, VarEnv(..))
import Compiler.Monomorphize.Analysis as Analysis
import Compiler.Monomorphize.Closure as Closure
import Compiler.Monomorphize.KernelAbi as KernelAbi
import Compiler.Monomorphize.Registry as Registry
import Compiler.Monomorphize.TypeSubst as TypeSubst
import Compiler.Reporting.Annotation as A
import Compiler.Type.SolverSnapshot as SolverSnapshot exposing (LocalView, SolverSnapshot, TypeVar)
import Data.Map as DMap
import Dict exposing (Dict)
import System.TypeCheck.IO as IO
import Utils.Crash


{-| Specialize a TOpt.Node into a MonoNode using solver-driven type resolution.
-}
specializeNode : SolverSnapshot -> Name -> TOpt.Node -> Mono.MonoType -> MonoDirectState -> ( Mono.MonoNode, MonoDirectState )
specializeNode snapshot ctorName node requestedMonoType state =
    case node of
        TOpt.Define expr _ meta ->
            specializeDefineNode snapshot expr meta requestedMonoType state

        TOpt.TrackedDefine _ expr _ meta ->
            specializeDefineNode snapshot expr meta requestedMonoType state

        TOpt.Ctor index arity canType ->
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


{-| Extract the solver variable from a meta, crashing if it's missing on a polymorphic type.
This enforces SNAP_TVAR_001: polymorphic nodes must have solver variables.
-}
requireTVar : String -> TOpt.Meta -> IO.Variable
requireTVar context meta =
    case meta.tvar of
        Just v ->
            v

        Nothing ->
            Utils.Crash.crash
                ("MonoDirect." ++ context ++ ": missing solver tvar for type "
                    ++ Debug.toString meta.tipe)


specializeDefineNode : SolverSnapshot -> TOpt.Expr -> TOpt.Meta -> Mono.MonoType -> MonoDirectState -> ( Mono.MonoNode, MonoDirectState )
specializeDefineNode snapshot expr meta requestedMonoType state =
    case meta.tvar of
        Just annotVar ->
            SolverSnapshot.specializeFunction snapshot annotVar requestedMonoType
                (\view ->
                    let
                        ( monoExpr, state1 ) =
                            specializeExpr view snapshot expr state
                    in
                    ( Mono.MonoDefine monoExpr (Mono.typeOf monoExpr), state1 )
                )

        Nothing ->
            if isMonomorphicCanType meta.tipe then
                -- Truly monomorphic synthetic node (e.g. record alias constructor).
                -- Safe to use empty unification context.
                SolverSnapshot.withLocalUnification snapshot [] []
                    (\view ->
                        let
                            ( monoExpr, state1 ) =
                                specializeExpr view snapshot expr state
                        in
                        ( Mono.MonoDefine monoExpr (Mono.typeOf monoExpr), state1 )
                    )

            else
                Utils.Crash.crash
                    ("MonoDirect.specializeDefineNode: missing solver tvar for polymorphic type "
                        ++ Debug.toString meta.tipe)



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
            SolverSnapshot.specializeFunction snapshot annotVar requestedMonoType
                (\view ->
                    let
                        ( monoExpr, state1 ) =
                            specializeExpr view snapshot expr state
                    in
                    ( nodeConstructor monoExpr requestedMonoType, state1 )
                )

        Nothing ->
            if isMonomorphicCanType meta.tipe then
                SolverSnapshot.withLocalUnification snapshot [] []
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
    case meta.tvar of
        Just tvar ->
            Mono.forceCNumberToInt (view.monoTypeOf tvar)

        Nothing ->
            if isMonomorphicCanType meta.tipe then
                -- Synthetic expression without solver variable (e.g. Let wrapper, Destruct wrapper,
                -- record alias constructor). Safe to fall back to direct Can.Type conversion.
                Mono.forceCNumberToInt (KernelAbi.canTypeToMonoType_preserveVars meta.tipe)

            else
                Utils.Crash.crash
                    ("MonoDirect.resolveType: missing solver tvar for polymorphic type "
                        ++ Debug.toString meta.tipe)


resolveExprType : LocalView -> TOpt.Expr -> Mono.MonoType
resolveExprType view expr =
    resolveType view (TOpt.metaOf expr)



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

        TOpt.VarDebug region name home _ meta ->
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
                monoType =
                    resolveType view meta

                ( monoItems, state1 ) =
                    specializeExprs view snapshot items state
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
                monoType =
                    resolveType view meta

                ( monoBranches, state1 ) =
                    specializeBranches view snapshot branches state

                ( monoFinal, state2 ) =
                    specializeExpr view snapshot final state1
            in
            ( Mono.MonoIf monoBranches monoFinal monoType, state2 )

        TOpt.Let def body meta ->
            specializeLet view snapshot def body meta state

        TOpt.Destruct destructor body meta ->
            let
                monoType =
                    resolveType view meta

                monoDestructor =
                    specializeDestructor view state.varEnv state.globalTypeEnv destructor

                -- Insert destructor binding into varEnv
                (TOpt.Destructor dName _ _) =
                    destructor

                destructorType =
                    specializeDestructorPathType view destructor

                state1 =
                    { state | varEnv = State.insertVar dName destructorType state.varEnv }

                ( monoBody, state2 ) =
                    specializeExpr view snapshot body state1
            in
            ( Mono.MonoDestruct monoDestructor monoBody monoType, state2 )

        TOpt.Case scrutName label decider jumps meta ->
            let
                monoType =
                    resolveType view meta

                ( monoDecider, state1 ) =
                    specializeDecider view snapshot decider state

                ( monoJumps, state2 ) =
                    specializeJumps view snapshot jumps state1
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

        TOpt.Update region recordExpr updates meta ->
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
                monoType =
                    resolveType view meta

                ( monoA, state1 ) =
                    specializeExpr view snapshot a state

                ( monoB, state2 ) =
                    specializeExpr view snapshot b state1

                ( monoRest, state3 ) =
                    specializeExprs view snapshot rest state2
            in
            ( Mono.MonoTupleCreate region (monoA :: monoB :: monoRest) monoType, state3 )

        -- Unit
        TOpt.Unit _ ->
            ( Mono.MonoUnit, state )

        -- Shader
        TOpt.Shader _ _ _ _ ->
            ( Mono.MonoUnit, state )




-- ========== CALL SPECIALIZATION ==========


specializeCall : LocalView -> SolverSnapshot -> A.Region -> TOpt.Expr -> List TOpt.Expr -> TOpt.Meta -> MonoDirectState -> ( Mono.MonoExpr, MonoDirectState )
specializeCall view snapshot region func args meta state =
    let
        resultType =
            resolveType view meta

        ( monoArgs, state1 ) =
            specializeExprs view snapshot args state
    in
    case func of
        TOpt.VarGlobal funcRegion global funcMeta ->
            let
                funcMonoType =
                    case funcMeta.tvar of
                        Just _ ->
                            resolveType view funcMeta

                        Nothing ->
                            -- Synthesized function reference (e.g. negate, binop operator)
                            -- without a solver variable. Build the function type from
                            -- the resolved argument types and result type.
                            let
                                argMonoTypes =
                                    List.map (\arg -> resolveExprType view arg) args
                            in
                            Mono.MFunction argMonoTypes resultType

                monoGlobal =
                    toptGlobalToMono global

                ( specId, state2 ) =
                    enqueueSpec monoGlobal funcMonoType Nothing state1

                monoFunc =
                    Mono.MonoVarGlobal funcRegion specId funcMonoType
            in
            ( Mono.MonoCall region monoFunc monoArgs resultType Mono.defaultCallInfo, state2 )

        TOpt.VarKernel funcRegion home name funcMeta ->
            let
                funcMonoType =
                    deriveKernelAbiTypeDirect ( home, name ) funcMeta view

                monoFunc =
                    Mono.MonoVarKernel funcRegion home name funcMonoType
            in
            ( Mono.MonoCall region monoFunc monoArgs resultType Mono.defaultCallInfo, state1 )

        TOpt.VarDebug funcRegion name home _ funcMeta ->
            let
                funcMonoType =
                    deriveKernelAbiTypeDirect ( "Debug", name ) funcMeta view

                monoFunc =
                    Mono.MonoVarKernel funcRegion "Debug" name funcMonoType
            in
            ( Mono.MonoCall region monoFunc monoArgs resultType Mono.defaultCallInfo, state1 )

        _ ->
            let
                ( monoFunc, state2 ) =
                    specializeExpr view snapshot func state1
            in
            ( Mono.MonoCall region monoFunc monoArgs resultType Mono.defaultCallInfo, state2 )



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
        TOpt.Def defRegion defName defExpr defCanType ->
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
            in
            ( Mono.MonoLet monoDef monoBody monoType, state3 )

        TOpt.TailDef defRegion defName defParams defBody defCanType defTvar ->
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

                -- Push frame for function params
                state1 =
                    { state | varEnv = State.pushFrame state.varEnv }

                state2 =
                    List.foldl
                        (\( name, mt ) s -> { s | varEnv = State.insertVar name mt s.varEnv })
                        state1
                        monoParams

                ( monoDefBody, state3 ) =
                    specializeExpr view snapshot defBody state2

                state4 =
                    { state3 | varEnv = State.popFrame state3.varEnv }

                -- Bind the function name in the outer scope
                state5 =
                    { state4 | varEnv = State.insertVar defName funcMonoType state4.varEnv }

                ( monoBody, state6 ) =
                    specializeExpr view snapshot body state5

                monoDef =
                    Mono.MonoTailDef defName monoParams monoDefBody
            in
            ( Mono.MonoLet monoDef monoBody monoType, state6 )



-- ========== CYCLE SPECIALIZATION ==========


specializeCycle : SolverSnapshot -> List Name -> List ( Name, TOpt.Expr ) -> List TOpt.Def -> Mono.MonoType -> MonoDirectState -> ( Mono.MonoNode, MonoDirectState )
specializeCycle snapshot names valueDefs funcDefs requestedMonoType state =
    -- Simple cycle handling: specialize value definitions under a shared view
    SolverSnapshot.withLocalUnification snapshot [] []
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
specializeBranches view snapshot branches state =
    List.foldl
        (\( cond, thenExpr ) ( acc, s ) ->
            let
                ( monoCond, s1 ) =
                    specializeExpr view snapshot cond s

                ( monoThen, s2 ) =
                    specializeExpr view snapshot thenExpr s1
            in
            ( acc ++ [ ( monoCond, monoThen ) ], s2 )
        )
        ( [], state )
        branches


specializeDecider : LocalView -> SolverSnapshot -> TOpt.Decider TOpt.Choice -> MonoDirectState -> ( Mono.Decider Mono.MonoChoice, MonoDirectState )
specializeDecider view snapshot decider state =
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
                ( monoSuccess, state1 ) =
                    specializeDecider view snapshot success state

                ( monoFailure, state2 ) =
                    specializeDecider view snapshot failure state1
            in
            ( Mono.Chain testChain monoSuccess monoFailure, state2 )

        TOpt.FanOut path tests fallback ->
            let
                ( monoTests, state1 ) =
                    List.foldl
                        (\( test, subDecider ) ( acc, s ) ->
                            let
                                ( monoSubDecider, s1 ) =
                                    specializeDecider view snapshot subDecider s
                            in
                            ( acc ++ [ ( test, monoSubDecider ) ], s1 )
                        )
                        ( [], state )
                        tests

                ( monoFallback, state2 ) =
                    specializeDecider view snapshot fallback state1
            in
            ( Mono.FanOut path monoTests monoFallback, state2 )


specializeJumps : LocalView -> SolverSnapshot -> List ( Int, TOpt.Expr ) -> MonoDirectState -> ( List ( Int, Mono.MonoExpr ), MonoDirectState )
specializeJumps view snapshot jumps state =
    List.foldl
        (\( idx, expr ) ( acc, s ) ->
            let
                ( monoExpr, s1 ) =
                    specializeExpr view snapshot expr s
            in
            ( acc ++ [ ( idx, monoExpr ) ], s1 )
        )
        ( [], state )
        jumps


specializeDestructor : LocalView -> VarEnv -> TypeEnv.GlobalTypeEnv -> TOpt.Destructor -> Mono.MonoDestructor
specializeDestructor view varEnv globalTypeEnv (TOpt.Destructor name path meta) =
    let
        monoType =
            resolveDestructorType view meta

        monoPath =
            specializePath view varEnv globalTypeEnv path
    in
    Mono.MonoDestructor name monoPath monoType


specializeDestructorPathType : LocalView -> TOpt.Destructor -> Mono.MonoType
specializeDestructorPathType view (TOpt.Destructor _ _ meta) =
    resolveDestructorType view meta


{-| Resolve destructor type via solver when tvar is available.
For destructors without tvar (e.g. PRecord field extractions), fall back
to direct Can.Type conversion which maps TVars to CEcoValue.
-}
resolveDestructorType : LocalView -> TOpt.Meta -> Mono.MonoType
resolveDestructorType view meta =
    case meta.tvar of
        Just tvar ->
            Mono.forceCNumberToInt (view.monoTypeOf tvar)

        Nothing ->
            Mono.forceCNumberToInt (KernelAbi.canTypeToMonoType_preserveVars meta.tipe)


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
                                            List.map2 Tuple.pair unionData.vars typeArgs
                                                |> List.foldl (\( varName, monoArg ) acc -> Dict.insert varName monoArg acc) Dict.empty
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
                                            List.map2 Tuple.pair unionData.vars typeArgs
                                                |> List.foldl (\( varName, monoArg ) acc -> Dict.insert varName monoArg acc) Dict.empty
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



-- ========== KERNEL ABI ==========


deriveKernelAbiTypeDirect : ( String, String ) -> TOpt.Meta -> LocalView -> Mono.MonoType
deriveKernelAbiTypeDirect ( home, name ) meta view =
    case meta.tvar of
        Just tvar ->
            let
                canType =
                    view.typeOf tvar

                monoType =
                    Mono.forceCNumberToInt (view.monoTypeOf tvar)

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
                        -- Map remaining vars (including number vars) to CEcoValue for boxed ABI
                        KernelAbi.canTypeToMonoType_preserveVars canType

                KernelAbi.PreserveVars ->
                    if isFullyMono then
                        monoType

                    else
                        KernelAbi.canTypeToMonoType_preserveVars canType

        Nothing ->
            Utils.Crash.crash "MonoDirect.deriveKernelAbiTypeDirect: kernel meta has no tvar"


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
    case monoType of
        Mono.MFunction args result ->
            if List.length args >= arity then
                result

            else
                monoType

        _ ->
            if arity == 0 then
                monoType

            else
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
