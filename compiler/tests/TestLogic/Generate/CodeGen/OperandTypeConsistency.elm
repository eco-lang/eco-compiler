module TestLogic.Generate.CodeGen.OperandTypeConsistency exposing (expectOperandTypeConsistency, checkOperandTypeConsistency)

{-| Test logic for CGEN\_040: Operand Type Consistency invariant.

For any operation with `_operand_types` attribute, the list length must equal
SSA operand count and each declared type must match the corresponding SSA
operand type.

@docs expectOperandTypeConsistency, checkOperandTypeConsistency

-}

import Compiler.AST.Source as Src
import Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..), MlirType(..))
import OrderedDict
import TestLogic.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( TypeEnv
        , Violation
        , extractOperandTypes
        , findFuncOps
        , typesMatch
        , violationsToExpectation
        )


{-| Verify that operand type consistency invariants hold for a source module.
-}
expectOperandTypeConsistency : Src.Module -> Expectation
expectOperandTypeConsistency srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkOperandTypeConsistency mlirModule)


{-| Check operand type consistency invariants.

This checks each function separately with its own scoped TypeEnv,
since SSA names are local to each function.

-}
checkOperandTypeConsistency : MlirModule -> List Violation
checkOperandTypeConsistency mlirModule =
    let
        funcOps =
            findFuncOps mlirModule

        violations =
            List.concatMap checkFunction funcOps
    in
    violations


checkFunction : MlirOp -> List Violation
checkFunction funcOp =
    let
        localTypeEnv =
            buildTypeEnvFromOp funcOp

        allOpsInFunc =
            walkOpsInOp funcOp
    in
    List.concatMap (checkOp localTypeEnv) allOpsInFunc


buildTypeEnvFromOp : MlirOp -> TypeEnv
buildTypeEnvFromOp op =
    let
        withResults =
            List.foldl
                (\( name, t ) acc -> Dict.insert name t acc)
                Dict.empty
                op.results

        withRegions =
            List.foldl collectFromRegion withResults op.regions
    in
    withRegions


collectFromRegion : MlirRegion -> TypeEnv -> TypeEnv
collectFromRegion (MlirRegion { entry, blocks }) env =
    let
        withEntryArgs =
            List.foldl
                (\( name, t ) acc -> Dict.insert name t acc)
                env
                entry.args

        withEntryBody =
            collectFromOps entry.body withEntryArgs

        withEntryTerm =
            collectFromOp entry.terminator withEntryBody

        withBlocks =
            List.foldl collectFromBlock withEntryTerm (OrderedDict.values blocks)
    in
    withBlocks


collectFromBlock : MlirBlock -> TypeEnv -> TypeEnv
collectFromBlock block env =
    let
        withArgs =
            List.foldl
                (\( name, t ) acc -> Dict.insert name t acc)
                env
                block.args

        withBody =
            collectFromOps block.body withArgs

        withTerm =
            collectFromOp block.terminator withBody
    in
    withTerm


collectFromOps : List MlirOp -> TypeEnv -> TypeEnv
collectFromOps ops env =
    List.foldl collectFromOp env ops


collectFromOp : MlirOp -> TypeEnv -> TypeEnv
collectFromOp op env =
    let
        withResults =
            List.foldl
                (\( name, t ) acc -> Dict.insert name t acc)
                env
                op.results

        withRegions =
            List.foldl collectFromRegion withResults op.regions
    in
    withRegions


walkOpsInOp : MlirOp -> List MlirOp
walkOpsInOp op =
    List.concatMap walkOpsInRegion op.regions


walkOpsInRegion : MlirRegion -> List MlirOp
walkOpsInRegion (MlirRegion { entry, blocks }) =
    let
        entryOps =
            List.concatMap walkOp entry.body ++ walkOp entry.terminator

        blockOps =
            List.concatMap walkOpsInBlock (OrderedDict.values blocks)
    in
    entryOps ++ blockOps


walkOpsInBlock : MlirBlock -> List MlirOp
walkOpsInBlock block =
    List.concatMap walkOp block.body ++ walkOp block.terminator


walkOp : MlirOp -> List MlirOp
walkOp op =
    op :: List.concatMap walkOpsInRegion op.regions


checkOp : TypeEnv -> MlirOp -> List Violation
checkOp typeEnv op =
    case extractOperandTypes op of
        Nothing ->
            []

        Just declaredTypes ->
            let
                operandCount =
                    List.length op.operands

                declaredCount =
                    List.length declaredTypes
            in
            if declaredCount /= operandCount then
                [ { opId = op.id
                  , opName = op.name
                  , message =
                        "_operand_types has "
                            ++ String.fromInt declaredCount
                            ++ " entries but op has "
                            ++ String.fromInt operandCount
                            ++ " operands"
                  }
                ]

            else
                List.indexedMap (checkOperandType typeEnv op) (List.map2 Tuple.pair op.operands declaredTypes)
                    |> List.filterMap identity


checkOperandType : TypeEnv -> MlirOp -> Int -> ( String, MlirType ) -> Maybe Violation
checkOperandType typeEnv op index ( operandName, declaredType ) =
    case Dict.get operandName typeEnv of
        Nothing ->
            Nothing

        Just actualType ->
            if typesMatch declaredType actualType then
                Nothing

            else
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "operand "
                            ++ String.fromInt index
                            ++ " ('"
                            ++ operandName
                            ++ "'): _operand_types declares "
                            ++ typeToString declaredType
                            ++ " but SSA type is "
                            ++ typeToString actualType
                    }


typeToString : MlirType -> String
typeToString t =
    case t of
        I1 ->
            "i1"

        I16 ->
            "i16"

        I32 ->
            "i32"

        I64 ->
            "i64"

        F64 ->
            "f64"

        NamedStruct name ->
            name

        FunctionType _ ->
            "function"
