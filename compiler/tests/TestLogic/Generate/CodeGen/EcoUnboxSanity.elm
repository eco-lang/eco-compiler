module TestLogic.Generate.CodeGen.EcoUnboxSanity exposing (expectEcoUnboxSanity, checkEcoUnboxSanity)

{-| Test logic for CGEN\_0E2: eco.unbox Sanity invariant.

eco.unbox converts !eco.value (boxed) to a primitive type (i1, i16, i64, f64).
This test verifies:

1.  The operand is !eco.value
2.  The result is a primitive type (i1, i16, i64, or f64)

Note: i32 is NOT a primitive in eco.

@docs expectEcoUnboxSanity, checkEcoUnboxSanity

-}

import Compiler.AST.Source as Src
import Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..), MlirType(..))
import OrderedDict
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( TypeEnv
        , Violation
        , findFuncOps
        , isEcoPrimitive
        , isEcoValueType
        , violationsToExpectation
        , walkOpsInRegion
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Verify that eco.unbox sanity invariants hold for a source module.
-}
expectEcoUnboxSanity : Src.Module -> Expectation
expectEcoUnboxSanity srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkEcoUnboxSanity mlirModule)


{-| Check that all eco.unbox ops have correct types.

This checks each function separately with its own scoped TypeEnv.

-}
checkEcoUnboxSanity : MlirModule -> List Violation
checkEcoUnboxSanity mlirModule =
    let
        funcOps =
            findFuncOps mlirModule
    in
    List.concatMap checkFunction funcOps


checkFunction : MlirOp -> List Violation
checkFunction funcOp =
    let
        typeEnv =
            buildTypeEnvFromOp funcOp

        allOps =
            walkOpsInOp funcOp

        unboxOps =
            List.filter (\op -> op.name == "eco.unbox") allOps
    in
    List.filterMap (checkUnboxOp typeEnv) unboxOps


checkUnboxOp : TypeEnv -> MlirOp -> Maybe Violation
checkUnboxOp typeEnv op =
    case op.operands of
        [ operandName ] ->
            case op.results of
                [ ( _, resultType ) ] ->
                    case Dict.get operandName typeEnv of
                        Nothing ->
                            Nothing

                        Just operandType ->
                            if not (isEcoValueType operandType) then
                                Just
                                    { opId = op.id
                                    , opName = op.name
                                    , message =
                                        "eco.unbox operand '"
                                            ++ operandName
                                            ++ "' is not eco.value, got "
                                            ++ typeToString operandType
                                    }

                            else if not (isEcoPrimitive resultType) then
                                Just
                                    { opId = op.id
                                    , opName = op.name
                                    , message =
                                        "eco.unbox result is not primitive, got "
                                            ++ typeToString resultType
                                    }

                            else
                                Nothing

                _ ->
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message =
                            "eco.unbox should have exactly 1 result, has "
                                ++ String.fromInt (List.length op.results)
                        }

        _ ->
            Just
                { opId = op.id
                , opName = op.name
                , message =
                    "eco.unbox should have exactly 1 operand, has "
                        ++ String.fromInt (List.length op.operands)
                }


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
            "!" ++ name

        FunctionType _ ->
            "function"
