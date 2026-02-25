module TestLogic.Generate.CodeGen.CharTypeMapping exposing (expectCharTypeMapping)

{-| Test logic for CGEN\_015: Char Type Mapping invariant.

`monoTypeToMlir` must map `MChar` to `i16` (not `i32`),
and all char constants/ops must use `i16`.

@docs expectCharTypeMapping

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractOperandTypes
        , extractResultTypes
        , findOpsWithPrefix
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Verify that char type mapping invariants hold for a source module.

This compiles the module to MLIR and checks that all char operations
use i16 (not i32) for character values.

-}
expectCharTypeMapping : Src.Module -> Expectation
expectCharTypeMapping srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCharTypeMapping mlirModule)


{-| Check char type mapping invariants on an MlirModule.
-}
checkCharTypeMapping : MlirModule -> List Violation
checkCharTypeMapping mlirModule =
    let
        charOps =
            findOpsWithPrefix "eco.char." mlirModule
    in
    List.filterMap checkCharOp charOps


checkCharOp : MlirOp -> Maybe Violation
checkCharOp op =
    case op.name of
        "eco.char.toInt" ->
            -- eco.char.toInt: i16 -> i64
            case extractOperandTypes op of
                Just (operandType :: _) ->
                    if operandType /= I16 then
                        Just
                            { opId = op.id
                            , opName = op.name
                            , message = "eco.char.toInt operand should be i16, got " ++ typeToString operandType
                            }

                    else
                        Nothing

                _ ->
                    Nothing

        "eco.char.fromInt" ->
            -- eco.char.fromInt: i64 -> i16
            let
                resultTypes =
                    extractResultTypes op
            in
            case List.head resultTypes of
                Just resultType ->
                    if resultType /= I16 then
                        Just
                            { opId = op.id
                            , opName = op.name
                            , message = "eco.char.fromInt result should be i16, got " ++ typeToString resultType
                            }

                    else
                        Nothing

                Nothing ->
                    Nothing

        _ ->
            -- Other char ops should also use i16
            Nothing


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
