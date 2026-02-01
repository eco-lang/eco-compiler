module Compiler.Type.Constrain.Typed.Expression exposing
    ( ExprIdState, emptyExprIdState
    , constrainDefWithIds, constrainRecursiveDefsWithIds
    )

{-| Type constraint generation for expressions (Typed pathway).

This module walks through canonical expression AST nodes and generates type constraints
while also tracking expression IDs to solver variables, enabling later retrieval of
expression types from the solver.


# Expression ID State

@docs ExprIdState, emptyExprIdState


# Constraint Generation with ID Tracking

@docs constrainDefWithIds, constrainRecursiveDefsWithIds

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Utils.Shader as Shader
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Type as E exposing (Category(..), Context(..), Expected(..), MaybeName(..), PContext(..), PExpected(..), SubContext(..))
import Compiler.Type.Constrain.Common as Common exposing (Args(..), Info(..), RigidTypeVar, State(..), TypedArgs(..), getAccessName, getName, makeArgs, toShaderRecord)
import Compiler.Type.Constrain.Typed.NodeIds as NodeIds
import Compiler.Type.Constrain.Typed.Pattern as Pattern
import Compiler.Type.Constrain.Typed.Program as Prog exposing (ProgS)
import Compiler.Type.Instantiate as Instantiate
import Compiler.Type.Type as Type exposing (Constraint(..), Type(..))
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as IO exposing (IO)
import Utils.Main as Utils



-- ====== Expression ID Tracking for TypedCanonical ======


{-| State for tracking node ID → Variable mappings during constraint generation.
-}
type alias ExprIdState =
    NodeIds.NodeIdState


{-| Initial empty state for node ID tracking.
-}
emptyExprIdState : ExprIdState
emptyExprIdState =
    NodeIds.emptyNodeIdState



-- ====== CONSTRAINT GENERATION WITH IDS ======


{-| Generate constraints for a definition, also tracking node IDs (expressions and patterns).
-}
constrainDefWithIds : RigidTypeVar -> Can.Def -> Constraint -> ExprIdState -> IO ( Constraint, ExprIdState )
constrainDefWithIds rtv def bodyCon state =
    case def of
        Can.Def (A.At region name) args expr ->
            constrainArgsWithIds args state
                |> IO.andThen
                    (\( Args props, stateAfterArgs ) ->
                        let
                            (State headers pvars revCons) =
                                props.state
                        in
                        constrainWithIds rtv expr (NoExpectation props.result) stateAfterArgs
                            |> IO.map
                                (\( exprCon, newState ) ->
                                    ( CLet []
                                        props.vars
                                        (Dict.singleton identity name (A.At region props.tipe))
                                        (CLet []
                                            pvars
                                            headers
                                            (CAnd (List.reverse revCons))
                                            exprCon
                                        )
                                        bodyCon
                                    , newState
                                    )
                                )
                    )

        Can.TypedDef (A.At region name) freeVars typedArgs expr srcResultType ->
            let
                newNames : Dict String Name ()
                newNames =
                    Dict.diff freeVars rtv
            in
            IO.traverseMapWithKey identity compare (\k _ -> Type.nameToRigid k) newNames
                |> IO.andThen
                    (\newRigids ->
                        let
                            newRtv : RigidTypeVar
                            newRtv =
                                Dict.union rtv (Dict.map (\_ -> VarN) newRigids)
                        in
                        constrainTypedArgsWithIds newRtv name typedArgs srcResultType state
                            |> IO.andThen
                                (\( TypedArgs tipe resultType (State headers pvars revCons), stateAfterArgs ) ->
                                    constrainWithIds newRtv expr (FromAnnotation name (List.length typedArgs) TypedBody resultType) stateAfterArgs
                                        |> IO.map
                                            (\( exprCon, newState ) ->
                                                ( CLet (Dict.values compare newRigids)
                                                    []
                                                    (Dict.singleton identity name (A.At region tipe))
                                                    (CLet []
                                                        pvars
                                                        headers
                                                        (CAnd (List.reverse revCons))
                                                        exprCon
                                                    )
                                                    bodyCon
                                                , newState
                                                )
                                            )
                                )
                    )


{-| Generate constraints for recursive definitions, also tracking node IDs (expressions and patterns).
-}
constrainRecursiveDefsWithIds : RigidTypeVar -> List Can.Def -> Constraint -> ExprIdState -> IO ( Constraint, ExprIdState )
constrainRecursiveDefsWithIds rtv defs bodyCon state =
    recDefsHelpWithIds rtv defs bodyCon (Info [] [] Dict.empty) (Info [] [] Dict.empty) state


recDefsHelpWithIds : RigidTypeVar -> List Can.Def -> Constraint -> Info -> Info -> ExprIdState -> IO ( Constraint, ExprIdState )
recDefsHelpWithIds rtv defs bodyCon rigidInfo flexInfo state =
    case defs of
        [] ->
            let
                (Info rigidVars rigidCons rigidHeaders) =
                    rigidInfo

                (Info flexVars flexCons flexHeaders) =
                    flexInfo
            in
            IO.pure
                ( CAnd [ CAnd rigidCons, bodyCon ]
                    |> CLet [] flexVars flexHeaders (CLet [] [] flexHeaders CTrue (CAnd flexCons))
                    |> CLet rigidVars [] rigidHeaders CTrue
                , state
                )

        def :: otherDefs ->
            case def of
                Can.Def (A.At region name) args expr ->
                    let
                        (Info flexVars flexCons flexHeaders) =
                            flexInfo
                    in
                    -- Match original: thread accumulated flexVars through pattern state
                    argsHelpWithIds args (State Dict.empty flexVars []) state
                        |> IO.andThen
                            (\( Args props, stateAfterArgs ) ->
                                let
                                    (State headers pvars revCons) =
                                        props.state
                                in
                                constrainWithIds rtv expr (NoExpectation props.result) stateAfterArgs
                                    |> IO.andThen
                                        (\( exprCon, newState ) ->
                                            let
                                                defCon : Constraint
                                                defCon =
                                                    CLet [] pvars headers (CAnd (List.reverse revCons)) exprCon

                                                -- Match original: just props.vars (flexVars already in pvars)
                                                newFlexInfo : Info
                                                newFlexInfo =
                                                    Info props.vars
                                                        (defCon :: flexCons)
                                                        (Dict.insert identity name (A.At region props.tipe) flexHeaders)
                                            in
                                            recDefsHelpWithIds rtv otherDefs bodyCon rigidInfo newFlexInfo newState
                                        )
                            )

                Can.TypedDef (A.At region name) freeVars typedArgs expr srcResultType ->
                    let
                        (Info rigidVars rigidCons rigidHeaders) =
                            rigidInfo

                        newNames : Dict String Name ()
                        newNames =
                            Dict.diff freeVars rtv
                    in
                    IO.traverseMapWithKey identity compare (\k _ -> Type.nameToRigid k) newNames
                        |> IO.andThen
                            (\newRigids ->
                                let
                                    newRtv : RigidTypeVar
                                    newRtv =
                                        Dict.union rtv (Dict.map (\_ -> VarN) newRigids)
                                in
                                constrainTypedArgsWithIds newRtv name typedArgs srcResultType state
                                    |> IO.andThen
                                        (\( TypedArgs tipe resultType (State headers pvars revCons), stateAfterArgs ) ->
                                            constrainWithIds newRtv expr (FromAnnotation name (List.length typedArgs) TypedBody resultType) stateAfterArgs
                                                |> IO.andThen
                                                    (\( exprCon, newState ) ->
                                                        let
                                                            -- Match original: defCon has empty rigid vars
                                                            defCon : Constraint
                                                            defCon =
                                                                CLet []
                                                                    pvars
                                                                    headers
                                                                    (CAnd (List.reverse revCons))
                                                                    exprCon

                                                            -- Match original: wrap defCon in CLet that introduces rigids
                                                            wrappedDefCon : Constraint
                                                            wrappedDefCon =
                                                                CLet (Dict.values compare newRigids) [] Dict.empty defCon CTrue

                                                            newRigidInfo : Info
                                                            newRigidInfo =
                                                                Info (Dict.foldr compare (\_ -> (::)) rigidVars newRigids) (wrappedDefCon :: rigidCons) (Dict.insert identity name (A.At region tipe) rigidHeaders)
                                                        in
                                                        recDefsHelpWithIds rtv otherDefs bodyCon newRigidInfo flexInfo newState
                                                    )
                                        )
                            )


{-| Generate constraints for a list of function argument patterns,
also tracking pattern IDs in the NodeIdState.
-}
constrainArgsWithIds : List Can.Pattern -> NodeIds.NodeIdState -> IO ( Args, NodeIds.NodeIdState )
constrainArgsWithIds args nodeState =
    argsHelpWithIds args Common.emptyState nodeState


{-| Helper for constraining function arguments with ID tracking.
Recursively processes patterns, threading through both the pattern state
and the NodeIdState, building up the function type.
-}
argsHelpWithIds : List Can.Pattern -> State -> NodeIds.NodeIdState -> IO ( Args, NodeIds.NodeIdState )
argsHelpWithIds args state nodeState =
    case args of
        [] ->
            Type.mkFlexVar
                |> IO.map
                    (\resultVar ->
                        let
                            resultType : Type
                            resultType =
                                VarN resultVar
                        in
                        ( makeArgs [ resultVar ] resultType resultType state, nodeState )
                    )

        pattern :: otherArgs ->
            Type.mkFlexVar
                |> IO.andThen
                    (\argVar ->
                        let
                            argType : Type
                            argType =
                                VarN argVar
                        in
                        Pattern.addWithIds pattern (PNoExpectation argType) state nodeState
                            |> IO.andThen
                                (\( newState, newNodeState ) ->
                                    argsHelpWithIds otherArgs newState newNodeState
                                )
                            |> IO.map
                                (\( Args props, finalNodeState ) ->
                                    ( makeArgs (argVar :: props.vars) (FunN argType props.tipe) props.result props.state
                                    , finalNodeState
                                    )
                                )
                    )


{-| Generate constraints for explicitly typed function arguments,
also tracking pattern IDs in the NodeIdState.
-}
constrainTypedArgsWithIds :
    Dict String Name Type
    -> Name
    -> List ( Can.Pattern, Can.Type )
    -> Can.Type
    -> NodeIds.NodeIdState
    -> IO ( TypedArgs, NodeIds.NodeIdState )
constrainTypedArgsWithIds rtv name args srcResultType nodeState =
    typedArgsHelpWithIds rtv name Index.first args srcResultType Common.emptyState nodeState


{-| Helper for constraining typed arguments with ID tracking.
Recursively processes pattern-type pairs with NodeIdState threading.
-}
typedArgsHelpWithIds :
    Dict String Name Type
    -> Name
    -> Index.ZeroBased
    -> List ( Can.Pattern, Can.Type )
    -> Can.Type
    -> State
    -> NodeIds.NodeIdState
    -> IO ( TypedArgs, NodeIds.NodeIdState )
typedArgsHelpWithIds rtv name index args srcResultType state nodeState =
    case args of
        [] ->
            Instantiate.fromSrcType rtv srcResultType
                |> IO.map
                    (\resultType ->
                        ( TypedArgs resultType resultType state, nodeState )
                    )

        ( (A.At region _) as pattern, srcType ) :: otherArgs ->
            Instantiate.fromSrcType rtv srcType
                |> IO.andThen
                    (\argType ->
                        let
                            expected : PExpected Type
                            expected =
                                PFromContext region (PTypedArg name index) argType
                        in
                        Pattern.addWithIds pattern expected state nodeState
                            |> IO.andThen
                                (\( newState, newNodeState ) ->
                                    typedArgsHelpWithIds rtv name (Index.next index) otherArgs srcResultType newState newNodeState
                                )
                            |> IO.map
                                (\( TypedArgs tipe resultType finalState, finalNodeState ) ->
                                    ( TypedArgs (FunN argType tipe) resultType finalState, finalNodeState )
                                )
                    )


{-| Generate constraints for an expression, tracking expression ID → Variable mapping.

This records the expression's ID and the type variable created for it in the state,
allowing post-solving conversion of variables to types.

-}
constrainWithIds : RigidTypeVar -> Can.Expr -> E.Expected Type -> ExprIdState -> IO ( Constraint, ExprIdState )
constrainWithIds rtv expr expected state =
    Prog.runS state (constrainWithIdsProg rtv expr expected)


{-| DSL version of constrainWithIds for stack safety.

This function dispatches to specialized helpers based on expression type:

  - Group A expressions (those with natural result variables) record their
    existing result var and avoid creating an extra exprVar + CEqual.
  - Group B expressions (without natural result variables) use the generic
    path that allocates a synthetic exprVar.

-}
constrainWithIdsProg : RigidTypeVar -> Can.Expr -> E.Expected Type -> ProgS ExprIdState Constraint
constrainWithIdsProg rtv (A.At region exprInfo) expected =
    case exprInfo.node of
        -- Group A: Use specialized helpers that record the natural result var
        Can.Int _ ->
            constrainIntWithIdsProg region exprInfo.id expected

        Can.Negate expr ->
            constrainNegateWithIdsProg rtv region exprInfo.id expr expected

        Can.Binop op _ _ annotation leftExpr rightExpr ->
            constrainBinopWithIdsProg rtv region exprInfo.id op annotation leftExpr rightExpr expected

        Can.Call func args ->
            constrainCallWithIdsProg rtv region exprInfo.id func args expected

        Can.If branches finally ->
            constrainIfWithIdsProg rtv region exprInfo.id branches finally expected

        Can.Case expr branches ->
            constrainCaseWithIdsProg rtv region exprInfo.id expr branches expected

        Can.Access expr (A.At accessRegion field) ->
            constrainAccessWithIdsProg rtv region exprInfo.id expr accessRegion field expected

        Can.Update expr fields ->
            constrainUpdateWithIdsProg rtv region exprInfo.id expr fields expected

        -- Group B: Use generic path with synthetic exprVar
        _ ->
            constrainGenericWithIdsProg rtv region exprInfo expected


{-| Generic WithIds implementation for expressions without natural result variables.

Allocates a synthetic exprVar for ID tracking, then generates constraints
matching the erased path, adding a CEqual to connect exprVar to the expected type.

-}
constrainGenericWithIdsProg : RigidTypeVar -> A.Region -> Can.ExprInfo -> E.Expected Type -> ProgS ExprIdState Constraint
constrainGenericWithIdsProg rtv region info expected =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\exprVar ->
                -- Use recordSyntheticExprVar to mark this as a Group B synthetic placeholder
                Prog.opModifyS (NodeIds.recordSyntheticExprVar info.id exprVar)
                    |> Prog.andThenS
                        (\() ->
                            let
                                exprType : Type
                                exprType =
                                    VarN exprVar
                            in
                            -- Pass through the original expected type to preserve constraint behavior
                            constrainNodeWithIdsProg rtv region info.node expected
                                |> Prog.mapS
                                    (\con ->
                                        Type.exists [ exprVar ]
                                            (CAnd
                                                [ con
                                                -- Unify exprVar with the expected type so nodeTypes gets the resolved type
                                                , CEqual region E.List exprType expected
                                                ]
                                            )
                                    )
                        )
            )


{-| Specialized Int handling - record the number variable directly.
-}
constrainIntWithIdsProg : A.Region -> Int -> E.Expected Type -> ProgS ExprIdState Constraint
constrainIntWithIdsProg region exprId expected =
    Prog.opMkFlexNumberS
        |> Prog.andThenS
            (\var ->
                Prog.opModifyS (NodeIds.recordNodeVar exprId var)
                    |> Prog.mapS
                        (\() ->
                            Type.exists [ var ] (CEqual region E.Number (VarN var) expected)
                        )
            )


{-| Specialized Negate handling - record the number variable directly.
-}
constrainNegateWithIdsProg : RigidTypeVar -> A.Region -> Int -> Can.Expr -> E.Expected Type -> ProgS ExprIdState Constraint
constrainNegateWithIdsProg rtv region exprId expr expected =
    Prog.opMkFlexNumberS
        |> Prog.andThenS
            (\numberVar ->
                Prog.opModifyS (NodeIds.recordNodeVar exprId numberVar)
                    |> Prog.andThenS
                        (\() ->
                            let
                                numberType : Type
                                numberType =
                                    VarN numberVar
                            in
                            constrainWithIdsProg rtv expr (FromContext region Negate numberType)
                                |> Prog.mapS
                                    (\numberCon ->
                                        Type.exists [ numberVar ]
                                            (CAnd [ numberCon, CEqual region E.Number numberType expected ])
                                    )
                        )
            )


{-| Specialized Access handling - record the field variable directly.
-}
constrainAccessWithIdsProg : RigidTypeVar -> A.Region -> Int -> Can.Expr -> A.Region -> Name -> E.Expected Type -> ProgS ExprIdState Constraint
constrainAccessWithIdsProg rtv region exprId expr accessRegion field expected =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\extVar ->
                Prog.opMkFlexVarS
                    |> Prog.andThenS
                        (\fieldVar ->
                            -- Record fieldVar as the type for this access expression
                            Prog.opModifyS (NodeIds.recordNodeVar exprId fieldVar)
                                |> Prog.andThenS
                                    (\() ->
                                        let
                                            extType : Type
                                            extType =
                                                VarN extVar

                                            fieldType : Type
                                            fieldType =
                                                VarN fieldVar

                                            recordType : Type
                                            recordType =
                                                RecordN (Dict.singleton identity field fieldType) extType

                                            context : Context
                                            context =
                                                RecordAccess (A.toRegion expr) (getAccessName expr) accessRegion field
                                        in
                                        constrainWithIdsProg rtv expr (FromContext region context recordType)
                                            |> Prog.mapS
                                                (\recordCon ->
                                                    Type.exists [ fieldVar, extVar ]
                                                        (CAnd
                                                            [ recordCon
                                                            , CEqual region (Access field) fieldType expected
                                                            ]
                                                        )
                                                )
                                    )
                        )
            )


{-| DSL version of constrainNodeWithIds for stack safety.
-}
constrainNodeWithIdsProg : RigidTypeVar -> A.Region -> Can.Expr_ -> E.Expected Type -> ProgS ExprIdState Constraint
constrainNodeWithIdsProg rtv region node expected =
    case node of
        Can.VarLocal name ->
            Prog.pureS (CLocal region name expected)

        Can.VarTopLevel _ name ->
            Prog.pureS (CLocal region name expected)

        Can.VarKernel _ _ ->
            Prog.pureS CTrue

        Can.VarForeign _ name annotation ->
            Prog.pureS (CForeign region name annotation expected)

        Can.VarCtor _ _ name _ annotation ->
            Prog.pureS (CForeign region name annotation expected)

        Can.VarDebug _ name annotation ->
            Prog.pureS (CForeign region name annotation expected)

        Can.VarOperator op _ _ annotation ->
            Prog.pureS (CForeign region op annotation expected)

        Can.Str _ ->
            Prog.pureS (CEqual region String Type.string expected)

        Can.Chr _ ->
            Prog.pureS (CEqual region Char Type.char expected)

        -- Group A: handled by constrainIntWithIdsProg
        Can.Int _ ->
            Prog.opMkFlexNumberS
                |> Prog.mapS (\var -> Type.exists [ var ] (CEqual region E.Number (VarN var) expected))

        Can.Float _ ->
            Prog.pureS (CEqual region Float Type.float expected)

        Can.Unit ->
            Prog.pureS (CEqual region Unit UnitN expected)

        Can.List elements ->
            constrainListWithIdsProg rtv region elements expected

        Can.Negate expr ->
            -- In generic path, create fresh var
            Prog.opMkFlexNumberS
                |> Prog.andThenS
                    (\numberVar ->
                        let
                            numberType : Type
                            numberType =
                                VarN numberVar
                        in
                        constrainWithIdsProg rtv expr (FromContext region Negate numberType)
                            |> Prog.mapS
                                (\numberCon ->
                                    Type.exists [ numberVar ]
                                        (CAnd [ numberCon, CEqual region E.Number numberType expected ])
                                )
                    )

        Can.Lambda args body ->
            constrainLambdaWithIdsProg rtv region args body expected

        Can.Binop op _ _ annotation leftExpr rightExpr ->
            constrainBinopNodeWithIdsProg rtv region op annotation leftExpr rightExpr expected

        Can.Call func argsList ->
            constrainCallNodeWithIdsProg rtv region func argsList expected

        Can.If branches finally ->
            constrainIfNodeWithIdsProg rtv region branches finally expected

        Can.Case expr branches ->
            constrainCaseNodeWithIdsProg rtv region expr branches expected

        Can.Let def body ->
            constrainWithIdsProg rtv body expected
                |> Prog.andThenS (constrainDefWithIdsProg rtv def)

        Can.LetRec defs body ->
            constrainWithIdsProg rtv body expected
                |> Prog.andThenS (constrainRecursiveDefsWithIdsProg rtv defs)

        Can.LetDestruct pattern expr body ->
            constrainWithIdsProg rtv body expected
                |> Prog.andThenS (constrainDestructWithIdsProg rtv region pattern expr)

        Can.Accessor field ->
            constrainAccessorWithIdsProg region field expected

        -- Group A: handled by constrainAccessWithIdsProg
        Can.Access _ _ ->
            -- Should not reach here since Access is handled by Group A dispatch
            Prog.pureS CTrue

        -- Group A: handled by constrainUpdateWithIdsProg
        Can.Update _ _ ->
            -- Should not reach here since Update is handled by Group A dispatch
            Prog.pureS CTrue

        Can.Record fields ->
            constrainRecordWithIdsProg rtv region fields expected

        Can.Tuple a b cs ->
            constrainTupleWithIdsProg rtv region a b cs expected

        Can.Shader _ types ->
            constrainShaderWithIdsProg region types expected



-- ====== Stack-Safe DSL-Based Constraint Generation (WithIds) ======


{-| DSL version of constrainShaderWithIds.
-}
constrainShaderWithIdsProg : A.Region -> Shader.Types -> Expected Type -> ProgS ExprIdState Constraint
constrainShaderWithIdsProg region (Shader.Types attributes uniforms varyings) expected =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\attrVar ->
                Prog.opMkFlexVarS
                    |> Prog.mapS
                        (\unifVar ->
                            let
                                attrType : Type
                                attrType =
                                    VarN attrVar

                                unifType : Type
                                unifType =
                                    VarN unifVar

                                shaderType : Type
                                shaderType =
                                    AppN ModuleName.webgl
                                        Name.shader
                                        [ toShaderRecord attributes attrType
                                        , toShaderRecord uniforms unifType
                                        , toShaderRecord varyings EmptyRecordN
                                        ]
                            in
                            Type.exists [ attrVar, unifVar ] (CEqual region Shader shaderType expected)
                        )
            )


constrainBinopWithIdsProg : RigidTypeVar -> A.Region -> Int -> Name -> Can.Annotation -> Can.Expr -> Can.Expr -> E.Expected Type -> ProgS ExprIdState Constraint
constrainBinopWithIdsProg rtv region exprId op annotation leftExpr rightExpr expected =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\leftVar ->
                Prog.opMkFlexVarS
                    |> Prog.andThenS
                        (\rightVar ->
                            Prog.opMkFlexVarS
                                |> Prog.andThenS
                                    (\answerVar ->
                                        -- Record answerVar as the type for this binop expression
                                        Prog.opModifyS (NodeIds.recordNodeVar exprId answerVar)
                                            |> Prog.andThenS
                                                (\() ->
                                                    let
                                                        leftType : Type
                                                        leftType =
                                                            VarN leftVar

                                                        rightType : Type
                                                        rightType =
                                                            VarN rightVar

                                                        answerType : Type
                                                        answerType =
                                                            VarN answerVar

                                                        binopType : Type
                                                        binopType =
                                                            Type.funType leftType (Type.funType rightType answerType)

                                                        opCon : Constraint
                                                        opCon =
                                                            CForeign region op annotation (NoExpectation binopType)
                                                    in
                                                    constrainWithIdsProg rtv leftExpr (FromContext region (OpLeft op) leftType)
                                                        |> Prog.andThenS
                                                            (\leftCon ->
                                                                constrainWithIdsProg rtv rightExpr (FromContext region (OpRight op) rightType)
                                                                    |> Prog.mapS
                                                                        (\rightCon ->
                                                                            Type.exists [ leftVar, rightVar, answerVar ]
                                                                                (CAnd
                                                                                    [ opCon
                                                                                    , leftCon
                                                                                    , rightCon
                                                                                    , CEqual region (CallResult (OpName op)) answerType expected
                                                                                    ]
                                                                                )
                                                                        )
                                                            )
                                                )
                                    )
                        )
            )


constrainBinopNodeWithIdsProg : RigidTypeVar -> A.Region -> Name -> Can.Annotation -> Can.Expr -> Can.Expr -> E.Expected Type -> ProgS ExprIdState Constraint
constrainBinopNodeWithIdsProg rtv region op annotation leftExpr rightExpr expected =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\leftVar ->
                Prog.opMkFlexVarS
                    |> Prog.andThenS
                        (\rightVar ->
                            Prog.opMkFlexVarS
                                |> Prog.andThenS
                                    (\answerVar ->
                                        let
                                            leftType : Type
                                            leftType =
                                                VarN leftVar

                                            rightType : Type
                                            rightType =
                                                VarN rightVar

                                            answerType : Type
                                            answerType =
                                                VarN answerVar

                                            binopType : Type
                                            binopType =
                                                Type.funType leftType (Type.funType rightType answerType)

                                            opCon : Constraint
                                            opCon =
                                                CForeign region op annotation (NoExpectation binopType)
                                        in
                                        constrainWithIdsProg rtv leftExpr (FromContext region (OpLeft op) leftType)
                                            |> Prog.andThenS
                                                (\leftCon ->
                                                    constrainWithIdsProg rtv rightExpr (FromContext region (OpRight op) rightType)
                                                        |> Prog.mapS
                                                            (\rightCon ->
                                                                Type.exists [ leftVar, rightVar, answerVar ]
                                                                    (CAnd
                                                                        [ opCon
                                                                        , leftCon
                                                                        , rightCon
                                                                        , CEqual region (CallResult (OpName op)) answerType expected
                                                                        ]
                                                                    )
                                                            )
                                                )
                                    )
                        )
            )


{-| DSL version of constrainListWithIds.
-}
constrainListWithIdsProg : RigidTypeVar -> A.Region -> List Can.Expr -> E.Expected Type -> ProgS ExprIdState Constraint
constrainListWithIdsProg rtv region entries expected =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\entryVar ->
                let
                    entryType : Type
                    entryType =
                        VarN entryVar

                    listType : Type
                    listType =
                        AppN ModuleName.list Name.list [ entryType ]
                in
                constrainListEntriesWithIdsProg rtv region entryType Index.first entries []
                    |> Prog.mapS
                        (\entryCons ->
                            Type.exists [ entryVar ]
                                (CAnd
                                    [ CAnd entryCons
                                    , CEqual region List listType expected
                                    ]
                                )
                        )
            )


{-| DSL version of constrainListEntriesWithIds.
-}
constrainListEntriesWithIdsProg : RigidTypeVar -> A.Region -> Type -> Index.ZeroBased -> List Can.Expr -> List Constraint -> ProgS ExprIdState (List Constraint)
constrainListEntriesWithIdsProg rtv region tipe index entries acc =
    case entries of
        [] ->
            Prog.pureS (List.reverse acc)

        entry :: rest ->
            constrainWithIdsProg rtv entry (FromContext region (ListEntry index) tipe)
                |> Prog.andThenS
                    (\entryCon ->
                        constrainListEntriesWithIdsProg rtv region tipe (Index.next index) rest (entryCon :: acc)
                    )


constrainIfWithIdsProg : RigidTypeVar -> A.Region -> Int -> List ( Can.Expr, Can.Expr ) -> Can.Expr -> E.Expected Type -> ProgS ExprIdState Constraint
constrainIfWithIdsProg rtv region exprId branches final expected =
    let
        boolExpect : Expected Type
        boolExpect =
            FromContext region IfCondition Type.bool

        ( conditions, exprs ) =
            List.foldr (\( c, e ) ( cs, es ) -> ( c :: cs, e :: es )) ( [], [ final ] ) branches
    in
    constrainExprsWithIdsProg rtv conditions boolExpect []
        |> Prog.andThenS
            (\condCons ->
                case expected of
                    FromAnnotation name arity _ tipe ->
                        -- Record ID with the expected type (tipe is the type var)
                        (case tipe of
                            VarN v ->
                                Prog.opModifyS (NodeIds.recordNodeVar exprId v)

                            _ ->
                                -- Need to create a var for tracking
                                Prog.opMkFlexVarS
                                    |> Prog.andThenS (\v -> Prog.opModifyS (NodeIds.recordNodeVar exprId v))
                        )
                            |> Prog.andThenS
                                (\() ->
                                    constrainIndexedExprsWithIdsProg rtv exprs (\index -> FromAnnotation name arity (TypedIfBranch index) tipe) Index.first []
                                        |> Prog.mapS
                                            (\branchCons ->
                                                CAnd (CAnd condCons :: branchCons)
                                            )
                                )

                    _ ->
                        Prog.opMkFlexVarS
                            |> Prog.andThenS
                                (\branchVar ->
                                    -- Record branchVar for this if expression
                                    Prog.opModifyS (NodeIds.recordNodeVar exprId branchVar)
                                        |> Prog.andThenS
                                            (\() ->
                                                let
                                                    branchType : Type
                                                    branchType =
                                                        VarN branchVar
                                                in
                                                constrainIndexedExprsWithIdsProg rtv exprs (\index -> FromContext region (IfBranch index) branchType) Index.first []
                                                    |> Prog.mapS
                                                        (\branchCons ->
                                                            Type.exists [ branchVar ]
                                                                (CAnd
                                                                    [ CAnd condCons
                                                                    , CAnd branchCons
                                                                    , CEqual region If branchType expected
                                                                    ]
                                                                )
                                                        )
                                            )
                                )
            )


constrainIfNodeWithIdsProg : RigidTypeVar -> A.Region -> List ( Can.Expr, Can.Expr ) -> Can.Expr -> E.Expected Type -> ProgS ExprIdState Constraint
constrainIfNodeWithIdsProg rtv region branches final expected =
    let
        boolExpect : Expected Type
        boolExpect =
            FromContext region IfCondition Type.bool

        ( conditions, exprs ) =
            List.foldr (\( c, e ) ( cs, es ) -> ( c :: cs, e :: es )) ( [], [ final ] ) branches
    in
    constrainExprsWithIdsProg rtv conditions boolExpect []
        |> Prog.andThenS
            (\condCons ->
                case expected of
                    FromAnnotation name arity _ tipe ->
                        constrainIndexedExprsWithIdsProg rtv exprs (\index -> FromAnnotation name arity (TypedIfBranch index) tipe) Index.first []
                            |> Prog.mapS (\branchCons -> CAnd (CAnd condCons :: branchCons))

                    _ ->
                        Prog.opMkFlexVarS
                            |> Prog.andThenS
                                (\branchVar ->
                                    let
                                        branchType : Type
                                        branchType =
                                            VarN branchVar
                                    in
                                    constrainIndexedExprsWithIdsProg rtv exprs (\index -> FromContext region (IfBranch index) branchType) Index.first []
                                        |> Prog.mapS
                                            (\branchCons ->
                                                Type.exists [ branchVar ]
                                                    (CAnd
                                                        [ CAnd condCons
                                                        , CAnd branchCons
                                                        , CEqual region If branchType expected
                                                        ]
                                                    )
                                            )
                                )
            )


constrainExprsWithIdsProg : RigidTypeVar -> List Can.Expr -> E.Expected Type -> List Constraint -> ProgS ExprIdState (List Constraint)
constrainExprsWithIdsProg rtv exprs expected acc =
    case exprs of
        [] ->
            Prog.pureS (List.reverse acc)

        expr :: rest ->
            constrainWithIdsProg rtv expr expected
                |> Prog.andThenS
                    (\con ->
                        constrainExprsWithIdsProg rtv rest expected (con :: acc)
                    )


constrainIndexedExprsWithIdsProg : RigidTypeVar -> List Can.Expr -> (Index.ZeroBased -> E.Expected Type) -> Index.ZeroBased -> List Constraint -> ProgS ExprIdState (List Constraint)
constrainIndexedExprsWithIdsProg rtv exprs mkExpected index acc =
    case exprs of
        [] ->
            Prog.pureS (List.reverse acc)

        expr :: rest ->
            constrainWithIdsProg rtv expr (mkExpected index)
                |> Prog.andThenS
                    (\con ->
                        constrainIndexedExprsWithIdsProg rtv rest mkExpected (Index.next index) (con :: acc)
                    )


constrainCaseWithIdsProg : RigidTypeVar -> A.Region -> Int -> Can.Expr -> List Can.CaseBranch -> Expected Type -> ProgS ExprIdState Constraint
constrainCaseWithIdsProg rtv region exprId expr branches expected =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\ptrnVar ->
                let
                    ptrnType : Type
                    ptrnType =
                        VarN ptrnVar

                    exprExpect : Expected Type
                    exprExpect =
                        NoExpectation ptrnType
                in
                case expected of
                    FromAnnotation name arity _ tipe ->
                        let
                            bodyExpect : Index.ZeroBased -> Expected Type
                            bodyExpect index =
                                FromAnnotation name arity (TypedCaseBranch index) tipe
                        in
                        -- Record ID with the expected type
                        (case tipe of
                            VarN v ->
                                -- Type is already a variable, just record it
                                Prog.opModifyS (NodeIds.recordNodeVar exprId v)
                                    |> Prog.mapS (\() -> Nothing)

                            _ ->
                                -- Type is concrete; create a flex var and constrain it to equal tipe
                                Prog.opMkFlexVarS
                                    |> Prog.andThenS
                                        (\v ->
                                            Prog.opModifyS (NodeIds.recordNodeVar exprId v)
                                                |> Prog.mapS (\() -> Just v)
                                        )
                        )
                            |> Prog.andThenS
                                (\maybeCaseVar ->
                                    constrainWithIdsProg rtv expr exprExpect
                                        |> Prog.andThenS
                                            (\exprCon ->
                                                constrainCaseBranchesWithIdsProg rtv region ptrnType branches bodyExpect Index.first []
                                                    |> Prog.mapS
                                                        (\branchCons ->
                                                            case maybeCaseVar of
                                                                Nothing ->
                                                                    -- tipe was VarN, no extra constraint needed
                                                                    Type.exists [ ptrnVar ] (CAnd (exprCon :: branchCons))

                                                                Just caseVar ->
                                                                    -- tipe was concrete, add constraint: caseVar = tipe
                                                                    Type.exists [ ptrnVar, caseVar ]
                                                                        (CAnd
                                                                            [ exprCon
                                                                            , CAnd branchCons
                                                                            , CEqual region Case (VarN caseVar) (NoExpectation tipe)
                                                                            ]
                                                                        )
                                                        )
                                            )
                                )

                    _ ->
                        Prog.opMkFlexVarS
                            |> Prog.andThenS
                                (\branchVar ->
                                    -- Record branchVar for this case expression
                                    Prog.opModifyS (NodeIds.recordNodeVar exprId branchVar)
                                        |> Prog.andThenS
                                            (\() ->
                                                let
                                                    branchType : Type
                                                    branchType =
                                                        VarN branchVar

                                                    bodyExpect : Index.ZeroBased -> Expected Type
                                                    bodyExpect index =
                                                        FromContext region (CaseBranch index) branchType
                                                in
                                                constrainWithIdsProg rtv expr exprExpect
                                                    |> Prog.andThenS
                                                        (\exprCon ->
                                                            constrainCaseBranchesWithIdsProg rtv region ptrnType branches bodyExpect Index.first []
                                                                |> Prog.mapS
                                                                    (\branchCons ->
                                                                        Type.exists [ ptrnVar, branchVar ]
                                                                            (CAnd
                                                                                [ exprCon
                                                                                , CAnd branchCons
                                                                                , CEqual region Case branchType expected
                                                                                ]
                                                                            )
                                                                    )
                                                        )
                                            )
                                )
            )


constrainCaseNodeWithIdsProg : RigidTypeVar -> A.Region -> Can.Expr -> List Can.CaseBranch -> Expected Type -> ProgS ExprIdState Constraint
constrainCaseNodeWithIdsProg rtv region expr branches expected =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\ptrnVar ->
                let
                    ptrnType : Type
                    ptrnType =
                        VarN ptrnVar

                    exprExpect : Expected Type
                    exprExpect =
                        NoExpectation ptrnType
                in
                case expected of
                    FromAnnotation name arity _ tipe ->
                        let
                            bodyExpect : Index.ZeroBased -> Expected Type
                            bodyExpect index =
                                FromAnnotation name arity (TypedCaseBranch index) tipe
                        in
                        constrainWithIdsProg rtv expr exprExpect
                            |> Prog.andThenS
                                (\exprCon ->
                                    constrainCaseBranchesWithIdsProg rtv region ptrnType branches bodyExpect Index.first []
                                        |> Prog.mapS
                                            (\branchCons ->
                                                Type.exists [ ptrnVar ] (CAnd (exprCon :: branchCons))
                                            )
                                )

                    _ ->
                        Prog.opMkFlexVarS
                            |> Prog.andThenS
                                (\branchVar ->
                                    let
                                        branchType : Type
                                        branchType =
                                            VarN branchVar

                                        bodyExpect : Index.ZeroBased -> Expected Type
                                        bodyExpect index =
                                            FromContext region (CaseBranch index) branchType
                                    in
                                    constrainWithIdsProg rtv expr exprExpect
                                        |> Prog.andThenS
                                            (\exprCon ->
                                                constrainCaseBranchesWithIdsProg rtv region ptrnType branches bodyExpect Index.first []
                                                    |> Prog.mapS
                                                        (\branchCons ->
                                                            Type.exists [ ptrnVar, branchVar ]
                                                                (CAnd
                                                                    [ exprCon
                                                                    , CAnd branchCons
                                                                    , CEqual region Case branchType expected
                                                                    ]
                                                                )
                                                        )
                                            )
                                )
            )


constrainCaseBranchesWithIdsProg : RigidTypeVar -> A.Region -> Type -> List Can.CaseBranch -> (Index.ZeroBased -> Expected Type) -> Index.ZeroBased -> List Constraint -> ProgS ExprIdState (List Constraint)
constrainCaseBranchesWithIdsProg rtv region ptrnType branches mkExpected index acc =
    case branches of
        [] ->
            Prog.pureS (List.reverse acc)

        branch :: rest ->
            constrainCaseBranchWithIdsProg rtv branch (PFromContext region (PCaseMatch index) ptrnType) (mkExpected index)
                |> Prog.andThenS
                    (\branchCon ->
                        constrainCaseBranchesWithIdsProg rtv region ptrnType rest mkExpected (Index.next index) (branchCon :: acc)
                    )


{-| DSL version of constrainCaseBranchWithIds.
-}
constrainCaseBranchWithIdsProg : RigidTypeVar -> Can.CaseBranch -> PExpected Type -> Expected Type -> ProgS ExprIdState Constraint
constrainCaseBranchWithIdsProg rtv (Can.CaseBranch pattern expr) pExpect bExpect =
    Prog.opGetS
        |> Prog.andThenS
            (\state ->
                Prog.opIOS (Pattern.addWithIds pattern pExpect Common.emptyState state)
                    |> Prog.andThenS
                        (\( State headers pvars revCons, newState ) ->
                            Prog.opModifyS (\_ -> newState)
                                |> Prog.andThenS
                                    (\() ->
                                        constrainWithIdsProg rtv expr bExpect
                                            |> Prog.mapS
                                                (\bodyCon ->
                                                    CLet [] pvars headers (CAnd (List.reverse revCons)) bodyCon
                                                )
                                    )
                        )
            )


{-| DSL version of constrainLambdaWithIds.
-}
constrainLambdaWithIdsProg : RigidTypeVar -> A.Region -> List Can.Pattern -> Can.Expr -> E.Expected Type -> ProgS ExprIdState Constraint
constrainLambdaWithIdsProg rtv region args body expected =
    Prog.opGetS
        |> Prog.andThenS
            (\state ->
                Prog.opIOS (constrainArgsWithIds args state)
                    |> Prog.andThenS
                        (\( Args props, newState ) ->
                            let
                                (State headers pvars revCons) =
                                    props.state
                            in
                            Prog.opModifyS (\_ -> newState)
                                |> Prog.andThenS
                                    (\() ->
                                        constrainWithIdsProg rtv body (NoExpectation props.result)
                                            |> Prog.mapS
                                                (\bodyCon ->
                                                    Type.exists props.vars <|
                                                        CAnd
                                                            [ CLet []
                                                                pvars
                                                                headers
                                                                (CAnd (List.reverse revCons))
                                                                bodyCon
                                                            , CEqual region Lambda props.tipe expected
                                                            ]
                                                )
                                    )
                        )
            )


constrainCallWithIdsProg : RigidTypeVar -> A.Region -> Int -> Can.Expr -> List Can.Expr -> E.Expected Type -> ProgS ExprIdState Constraint
constrainCallWithIdsProg rtv region exprId ((A.At funcRegion _) as func) args expected =
    let
        maybeName : MaybeName
        maybeName =
            getName func
    in
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\funcVar ->
                Prog.opMkFlexVarS
                    |> Prog.andThenS
                        (\resultVar ->
                            -- Record resultVar for this call expression
                            Prog.opModifyS (NodeIds.recordNodeVar exprId resultVar)
                                |> Prog.andThenS
                                    (\() ->
                                        let
                                            funcType : Type
                                            funcType =
                                                VarN funcVar

                                            resultType : Type
                                            resultType =
                                                VarN resultVar
                                        in
                                        constrainWithIdsProg rtv func (E.NoExpectation funcType)
                                            |> Prog.andThenS
                                                (\funcCon ->
                                                    constrainCallArgsWithIdsProg rtv region maybeName Index.first args [] [] []
                                                        |> Prog.mapS
                                                            (\( argVars, argTypes, argCons ) ->
                                                                let
                                                                    arityType : Type
                                                                    arityType =
                                                                        List.foldr FunN resultType argTypes

                                                                    category : Category
                                                                    category =
                                                                        CallResult maybeName
                                                                in
                                                                Type.exists (funcVar :: resultVar :: argVars)
                                                                    (CAnd
                                                                        [ funcCon
                                                                        , CEqual funcRegion category funcType (FromContext region (CallArity maybeName (List.length args)) arityType)
                                                                        , CAnd argCons
                                                                        , CEqual region category resultType expected
                                                                        ]
                                                                    )
                                                            )
                                                )
                                    )
                        )
            )


constrainCallNodeWithIdsProg : RigidTypeVar -> A.Region -> Can.Expr -> List Can.Expr -> E.Expected Type -> ProgS ExprIdState Constraint
constrainCallNodeWithIdsProg rtv region ((A.At funcRegion _) as func) args expected =
    let
        maybeName : MaybeName
        maybeName =
            getName func
    in
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\funcVar ->
                Prog.opMkFlexVarS
                    |> Prog.andThenS
                        (\resultVar ->
                            let
                                funcType : Type
                                funcType =
                                    VarN funcVar

                                resultType : Type
                                resultType =
                                    VarN resultVar
                            in
                            constrainWithIdsProg rtv func (E.NoExpectation funcType)
                                |> Prog.andThenS
                                    (\funcCon ->
                                        constrainCallArgsWithIdsProg rtv region maybeName Index.first args [] [] []
                                            |> Prog.mapS
                                                (\( argVars, argTypes, argCons ) ->
                                                    let
                                                        arityType : Type
                                                        arityType =
                                                            List.foldr FunN resultType argTypes

                                                        category : Category
                                                        category =
                                                            CallResult maybeName
                                                    in
                                                    Type.exists (funcVar :: resultVar :: argVars)
                                                        (CAnd
                                                            [ funcCon
                                                            , CEqual funcRegion category funcType (FromContext region (CallArity maybeName (List.length args)) arityType)
                                                            , CAnd argCons
                                                            , CEqual region category resultType expected
                                                            ]
                                                        )
                                                )
                                    )
                        )
            )


constrainCallArgsWithIdsProg : RigidTypeVar -> A.Region -> E.MaybeName -> Index.ZeroBased -> List Can.Expr -> List IO.Variable -> List Type -> List Constraint -> ProgS ExprIdState ( List IO.Variable, List Type, List Constraint )
constrainCallArgsWithIdsProg rtv region maybeName index args accVars accTypes accCons =
    case args of
        [] ->
            Prog.pureS ( List.reverse accVars, List.reverse accTypes, List.reverse accCons )

        arg :: rest ->
            Prog.opMkFlexVarS
                |> Prog.andThenS
                    (\argVar ->
                        let
                            argType : Type
                            argType =
                                VarN argVar
                        in
                        constrainWithIdsProg rtv arg (FromContext region (CallArg maybeName index) argType)
                            |> Prog.andThenS
                                (\argCon ->
                                    constrainCallArgsWithIdsProg rtv region maybeName (Index.next index) rest (argVar :: accVars) (argType :: accTypes) (argCon :: accCons)
                                )
                    )


{-| DSL version of constrainRecordWithIds.
-}
constrainRecordWithIdsProg : RigidTypeVar -> A.Region -> Dict String (A.Located Name) Can.Expr -> Expected Type -> ProgS ExprIdState Constraint
constrainRecordWithIdsProg rtv region fields expected =
    let
        fieldList : List ( A.Located Name, Can.Expr )
        fieldList =
            Dict.toList A.compareLocated fields
    in
    constrainFieldsWithIdsProg rtv fieldList []
        |> Prog.mapS
            (\fieldResults ->
                let
                    dict : Dict String (A.Located Name) ( IO.Variable, Type, Constraint )
                    dict =
                        Dict.fromList A.toValue fieldResults

                    getTypeFromResult : a -> ( b, c, d ) -> c
                    getTypeFromResult _ ( _, t, _ ) =
                        t

                    recordType : Type
                    recordType =
                        RecordN (Utils.mapMapKeys identity A.compareLocated A.toValue (Dict.map getTypeFromResult dict)) EmptyRecordN

                    recordCon : Constraint
                    recordCon =
                        CEqual region Record recordType expected

                    vars : List IO.Variable
                    vars =
                        Dict.foldr A.compareLocated (\_ ( v, _, _ ) vs -> v :: vs) [] dict

                    cons : List Constraint
                    cons =
                        Dict.foldr A.compareLocated (\_ ( _, _, c ) cs -> c :: cs) [ recordCon ] dict
                in
                Type.exists vars (CAnd cons)
            )


constrainFieldsWithIdsProg : RigidTypeVar -> List ( A.Located Name, Can.Expr ) -> List ( A.Located Name, ( IO.Variable, Type, Constraint ) ) -> ProgS ExprIdState (List ( A.Located Name, ( IO.Variable, Type, Constraint ) ))
constrainFieldsWithIdsProg rtv fields acc =
    case fields of
        [] ->
            Prog.pureS (List.reverse acc)

        ( locName, expr ) :: rest ->
            Prog.opMkFlexVarS
                |> Prog.andThenS
                    (\fieldVar ->
                        let
                            fieldType : Type
                            fieldType =
                                VarN fieldVar
                        in
                        constrainWithIdsProg rtv expr (NoExpectation fieldType)
                            |> Prog.andThenS
                                (\fieldCon ->
                                    constrainFieldsWithIdsProg rtv rest (( locName, ( fieldVar, fieldType, fieldCon ) ) :: acc)
                                )
                    )


constrainUpdateWithIdsProg : RigidTypeVar -> A.Region -> Int -> Can.Expr -> Dict String (A.Located Name) Can.FieldUpdate -> Expected Type -> ProgS ExprIdState Constraint
constrainUpdateWithIdsProg rtv region exprId expr locatedFields expected =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\extVar ->
                Prog.opMkFlexVarS
                    |> Prog.andThenS
                        (\recordVar ->
                            -- Record recordVar for this update expression
                            Prog.opModifyS (NodeIds.recordNodeVar exprId recordVar)
                                |> Prog.andThenS
                                    (\() ->
                                        let
                                            fields : Dict String Name Can.FieldUpdate
                                            fields =
                                                Utils.mapMapKeys identity A.compareLocated A.toValue locatedFields

                                            updateList : List ( Name, Can.FieldUpdate )
                                            updateList =
                                                Dict.toList compare fields
                                        in
                                        constrainUpdateFieldsWithIdsProg rtv region updateList []
                                            |> Prog.andThenS
                                                (\fieldResults ->
                                                    let
                                                        fieldDict : Dict String Name ( IO.Variable, Type, Constraint )
                                                        fieldDict =
                                                            Dict.fromList identity fieldResults

                                                        recordType : Type
                                                        recordType =
                                                            VarN recordVar

                                                        fieldsType : Type
                                                        fieldsType =
                                                            RecordN (Dict.map (\_ ( _, t, _ ) -> t) fieldDict) (VarN extVar)

                                                        fieldsCon : Constraint
                                                        fieldsCon =
                                                            CEqual region Record recordType (NoExpectation fieldsType)

                                                        recordCon : Constraint
                                                        recordCon =
                                                            CEqual region Record recordType expected

                                                        vars : List IO.Variable
                                                        vars =
                                                            Dict.foldr compare (\_ ( v, _, _ ) vs -> v :: vs) [ recordVar, extVar ] fieldDict

                                                        cons : List Constraint
                                                        cons =
                                                            Dict.foldr compare (\_ ( _, _, c ) cs -> c :: cs) [ recordCon ] fieldDict
                                                    in
                                                    constrainWithIdsProg rtv expr (FromContext region (RecordUpdateKeys fields) recordType)
                                                        |> Prog.mapS
                                                            (\exprCon ->
                                                                Type.exists vars (CAnd (fieldsCon :: exprCon :: cons))
                                                            )
                                                )
                                    )
                        )
            )


constrainUpdateFieldsWithIdsProg : RigidTypeVar -> A.Region -> List ( Name, Can.FieldUpdate ) -> List ( Name, ( IO.Variable, Type, Constraint ) ) -> ProgS ExprIdState (List ( Name, ( IO.Variable, Type, Constraint ) ))
constrainUpdateFieldsWithIdsProg rtv _ fields acc =
    case fields of
        [] ->
            Prog.pureS (List.reverse acc)

        ( name, Can.FieldUpdate fieldRegion expr ) :: rest ->
            Prog.opMkFlexVarS
                |> Prog.andThenS
                    (\fieldVar ->
                        let
                            fieldType : Type
                            fieldType =
                                VarN fieldVar

                            expectation : Expected Type
                            expectation =
                                FromContext fieldRegion (RecordUpdateValue name) fieldType
                        in
                        constrainWithIdsProg rtv expr expectation
                            |> Prog.andThenS
                                (\fieldCon ->
                                    constrainUpdateFieldsWithIdsProg rtv fieldRegion rest (( name, ( fieldVar, fieldType, fieldCon ) ) :: acc)
                                )
                    )


{-| DSL version of constrainTupleWithIds.
-}
constrainTupleWithIdsProg : RigidTypeVar -> A.Region -> Can.Expr -> Can.Expr -> List Can.Expr -> Expected Type -> ProgS ExprIdState Constraint
constrainTupleWithIdsProg rtv region a b cs expected =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\aVar ->
                Prog.opMkFlexVarS
                    |> Prog.andThenS
                        (\bVar ->
                            let
                                aType : Type
                                aType =
                                    VarN aVar

                                bType : Type
                                bType =
                                    VarN bVar
                            in
                            constrainWithIdsProg rtv a (NoExpectation aType)
                                |> Prog.andThenS
                                    (\aCon ->
                                        constrainWithIdsProg rtv b (NoExpectation bType)
                                            |> Prog.andThenS
                                                (\bCon ->
                                                    constrainTupleRestWithIdsProg rtv region cs [] []
                                                        |> Prog.mapS
                                                            (\( cCons, cVars ) ->
                                                                let
                                                                    tupleType : Type
                                                                    tupleType =
                                                                        TupleN aType bType (List.map VarN cVars)

                                                                    tupleCon : Constraint
                                                                    tupleCon =
                                                                        CEqual region Tuple tupleType expected
                                                                in
                                                                Type.exists (aVar :: bVar :: cVars) (CAnd (aCon :: bCon :: cCons ++ [ tupleCon ]))
                                                            )
                                                )
                                    )
                        )
            )


constrainTupleRestWithIdsProg : RigidTypeVar -> A.Region -> List Can.Expr -> List Constraint -> List IO.Variable -> ProgS ExprIdState ( List Constraint, List IO.Variable )
constrainTupleRestWithIdsProg rtv _ cs accCons accVars =
    case cs of
        [] ->
            Prog.pureS ( List.reverse accCons, List.reverse accVars )

        ((A.At cRegion _) as c) :: rest ->
            Prog.opMkFlexVarS
                |> Prog.andThenS
                    (\cVar ->
                        let
                            cType : Type
                            cType =
                                VarN cVar
                        in
                        constrainWithIdsProg rtv c (NoExpectation cType)
                            |> Prog.andThenS
                                (\cCon ->
                                    constrainTupleRestWithIdsProg rtv cRegion rest (cCon :: accCons) (cVar :: accVars)
                                )
                    )


{-| DSL version of constrainAccessorWithIds.
-}
constrainAccessorWithIdsProg : A.Region -> Name -> Expected Type -> ProgS ExprIdState Constraint
constrainAccessorWithIdsProg region field expected =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\extVar ->
                Prog.opMkFlexVarS
                    |> Prog.mapS
                        (\fieldVar ->
                            let
                                extType : Type
                                extType =
                                    VarN extVar

                                fieldType : Type
                                fieldType =
                                    VarN fieldVar

                                recordType : Type
                                recordType =
                                    RecordN (Dict.singleton identity field fieldType) extType
                            in
                            Type.exists [ fieldVar, extVar ] (CEqual region (Accessor field) (FunN recordType fieldType) expected)
                        )
            )


{-| DSL version of constrainDestructWithIds.
-}
constrainDestructWithIdsProg : RigidTypeVar -> A.Region -> Can.Pattern -> Can.Expr -> Constraint -> ProgS ExprIdState Constraint
constrainDestructWithIdsProg rtv region pattern expr bodyCon =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\patternVar ->
                let
                    patternType : Type
                    patternType =
                        VarN patternVar
                in
                Prog.opGetS
                    |> Prog.andThenS
                        (\state ->
                            Prog.opIOS (Pattern.addWithIds pattern (PNoExpectation patternType) Common.emptyState state)
                                |> Prog.andThenS
                                    (\( State headers pvars revCons, newState ) ->
                                        Prog.opModifyS (\_ -> newState)
                                            |> Prog.andThenS
                                                (\() ->
                                                    constrainWithIdsProg rtv expr (FromContext region Destructure patternType)
                                                        |> Prog.mapS
                                                            (\exprCon ->
                                                                CLet [] (patternVar :: pvars) headers (CAnd (List.reverse (exprCon :: revCons))) bodyCon
                                                            )
                                                )
                                    )
                        )
            )


{-| DSL version of constrainDefWithIds.
-}
constrainDefWithIdsProg : RigidTypeVar -> Can.Def -> Constraint -> ProgS ExprIdState Constraint
constrainDefWithIdsProg rtv def bodyCon =
    case def of
        Can.Def (A.At region name) args expr ->
            Prog.opGetS
                |> Prog.andThenS
                    (\state ->
                        Prog.opIOS (constrainArgsWithIds args state)
                            |> Prog.andThenS
                                (\( Args props, newState ) ->
                                    let
                                        (State headers pvars revCons) =
                                            props.state
                                    in
                                    Prog.opModifyS (\_ -> newState)
                                        |> Prog.andThenS
                                            (\() ->
                                                constrainWithIdsProg rtv expr (NoExpectation props.result)
                                                    |> Prog.mapS
                                                        (\exprCon ->
                                                            CLet []
                                                                props.vars
                                                                (Dict.singleton identity name (A.At region props.tipe))
                                                                (CLet []
                                                                    pvars
                                                                    headers
                                                                    (CAnd (List.reverse revCons))
                                                                    exprCon
                                                                )
                                                                bodyCon
                                                        )
                                            )
                                )
                    )

        Can.TypedDef (A.At region name) freeVars typedArgs expr srcResultType ->
            let
                newNames : Dict String Name ()
                newNames =
                    Dict.diff freeVars rtv
            in
            Prog.opIOS (IO.traverseMapWithKey identity compare (\k _ -> Type.nameToRigid k) newNames)
                |> Prog.andThenS
                    (\newRigids ->
                        let
                            newRtv : RigidTypeVar
                            newRtv =
                                Dict.union rtv (Dict.map (\_ -> VarN) newRigids)
                        in
                        Prog.opGetS
                            |> Prog.andThenS
                                (\state ->
                                    Prog.opIOS (constrainTypedArgsWithIds newRtv name typedArgs srcResultType state)
                                        |> Prog.andThenS
                                            (\( TypedArgs tipe resultType (State headers pvars revCons), newState ) ->
                                                Prog.opModifyS (\_ -> newState)
                                                    |> Prog.andThenS
                                                        (\() ->
                                                            constrainWithIdsProg newRtv expr (FromAnnotation name (List.length typedArgs) TypedBody resultType)
                                                                |> Prog.mapS
                                                                    (\exprCon ->
                                                                        CLet (Dict.values compare newRigids)
                                                                            []
                                                                            (Dict.singleton identity name (A.At region tipe))
                                                                            (CLet []
                                                                                pvars
                                                                                headers
                                                                                (CAnd (List.reverse revCons))
                                                                                exprCon
                                                                            )
                                                                            bodyCon
                                                                    )
                                                        )
                                            )
                                )
                    )


{-| DSL version of constrainRecursiveDefsWithIds.
-}
constrainRecursiveDefsWithIdsProg : RigidTypeVar -> List Can.Def -> Constraint -> ProgS ExprIdState Constraint
constrainRecursiveDefsWithIdsProg rtv defs bodyCon =
    recDefsHelpWithIdsProg rtv defs bodyCon (Info [] [] Dict.empty) (Info [] [] Dict.empty)


recDefsHelpWithIdsProg : RigidTypeVar -> List Can.Def -> Constraint -> Info -> Info -> ProgS ExprIdState Constraint
recDefsHelpWithIdsProg rtv defs bodyCon rigidInfo flexInfo =
    case defs of
        [] ->
            let
                (Info rigidVars rigidCons rigidHeaders) =
                    rigidInfo

                (Info flexVars flexCons flexHeaders) =
                    flexInfo
            in
            Prog.pureS
                (CAnd [ CAnd rigidCons, bodyCon ]
                    |> CLet [] flexVars flexHeaders (CLet [] [] flexHeaders CTrue (CAnd flexCons))
                    |> CLet rigidVars [] rigidHeaders CTrue
                )

        def :: otherDefs ->
            case def of
                Can.Def (A.At region name) args expr ->
                    let
                        (Info flexVars flexCons flexHeaders) =
                            flexInfo
                    in
                    Prog.opGetS
                        |> Prog.andThenS
                            (\state ->
                                Prog.opIOS (argsHelpWithIds args (State Dict.empty flexVars []) state)
                                    |> Prog.andThenS
                                        (\( Args props, newState ) ->
                                            let
                                                (State headers pvars revCons) =
                                                    props.state
                                            in
                                            Prog.opModifyS (\_ -> newState)
                                                |> Prog.andThenS
                                                    (\() ->
                                                        constrainWithIdsProg rtv expr (NoExpectation props.result)
                                                            |> Prog.andThenS
                                                                (\exprCon ->
                                                                    let
                                                                        defCon : Constraint
                                                                        defCon =
                                                                            CLet [] pvars headers (CAnd (List.reverse revCons)) exprCon

                                                                        newFlexInfo : Info
                                                                        newFlexInfo =
                                                                            Info props.vars
                                                                                (defCon :: flexCons)
                                                                                (Dict.insert identity name (A.At region props.tipe) flexHeaders)
                                                                    in
                                                                    recDefsHelpWithIdsProg rtv otherDefs bodyCon rigidInfo newFlexInfo
                                                                )
                                                    )
                                        )
                            )

                Can.TypedDef (A.At region name) freeVars typedArgs expr srcResultType ->
                    let
                        (Info rigidVars rigidCons rigidHeaders) =
                            rigidInfo

                        newNames : Dict String Name ()
                        newNames =
                            Dict.diff freeVars rtv
                    in
                    Prog.opIOS (IO.traverseMapWithKey identity compare (\k _ -> Type.nameToRigid k) newNames)
                        |> Prog.andThenS
                            (\newRigids ->
                                let
                                    newRtv : RigidTypeVar
                                    newRtv =
                                        Dict.union rtv (Dict.map (\_ -> VarN) newRigids)
                                in
                                Prog.opGetS
                                    |> Prog.andThenS
                                        (\state ->
                                            Prog.opIOS (constrainTypedArgsWithIds newRtv name typedArgs srcResultType state)
                                                |> Prog.andThenS
                                                    (\( TypedArgs tipe resultType (State headers pvars revCons), newState ) ->
                                                        Prog.opModifyS (\_ -> newState)
                                                            |> Prog.andThenS
                                                                (\() ->
                                                                    constrainWithIdsProg newRtv expr (FromAnnotation name (List.length typedArgs) TypedBody resultType)
                                                                        |> Prog.andThenS
                                                                            (\exprCon ->
                                                                                let
                                                                                    defCon : Constraint
                                                                                    defCon =
                                                                                        CLet []
                                                                                            pvars
                                                                                            headers
                                                                                            (CAnd (List.reverse revCons))
                                                                                            exprCon

                                                                                    wrappedDefCon : Constraint
                                                                                    wrappedDefCon =
                                                                                        CLet (Dict.values compare newRigids) [] Dict.empty defCon CTrue

                                                                                    newRigidInfo : Info
                                                                                    newRigidInfo =
                                                                                        Info (Dict.foldr compare (\_ -> (::)) rigidVars newRigids) (wrappedDefCon :: rigidCons) (Dict.insert identity name (A.At region tipe) rigidHeaders)
                                                                                in
                                                                                recDefsHelpWithIdsProg rtv otherDefs bodyCon newRigidInfo flexInfo
                                                                            )
                                                                )
                                                    )
                                        )
                            )
