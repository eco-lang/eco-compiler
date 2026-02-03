module TestLogic.Generate.CodeGen.BoxingValidation exposing (expectBoxingValidation, checkBoxingValidation)

{-| Test logic for CGEN\_001: Boxing Validation invariant.

Boxing operations must only convert between primitive MLIR types (i64, f64, i16)
and `!eco.value`. Any conversion between mismatched primitives or no-op
boxing/unboxing is a violation.

@docs expectBoxingValidation, checkBoxingValidation

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractOperandTypes
        , extractResultTypes
        , findOpsNamed
        , isEcoValueType
        , isUnboxable
        , violationsToExpectation
        )


{-| Verify that boxing validation invariants hold for a source module.
-}
expectBoxingValidation : Src.Module -> Expectation
expectBoxingValidation srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkBoxingValidation mlirModule)


{-| Check boxing/unboxing operations for validity.

CGEN\_001: Boxing ops must convert between primitives (i64, f64, i16) and !eco.value only.

-}
checkBoxingValidation : MlirModule -> List Violation
checkBoxingValidation mlirModule =
    let
        boxOps =
            findOpsNamed "eco.box" mlirModule

        unboxOps =
            findOpsNamed "eco.unbox" mlirModule

        boxViolations =
            List.filterMap checkBoxOp boxOps

        unboxViolations =
            List.filterMap checkUnboxOp unboxOps
    in
    boxViolations ++ unboxViolations


{-| Check a single eco.box operation.

eco.box must:

  - Have input operand of primitive type (i64, f64, i16, or i1 for Bool)
  - Have result of !eco.value type

Note: i1 (Bool) is allowed as input because Bool values are unboxed to i1
for control flow (case scrutinee) and then boxed back to !eco.value.
The heap/closure storage checks (CGEN\_003, 026, 027, 049) verify that
i1 is not stored unboxed in heap objects.

-}
checkBoxOp : MlirOp -> Maybe Violation
checkBoxOp op =
    case ( extractOperandTypes op, extractResultTypes op ) of
        ( Just [ inputType ], [ resultType ] ) ->
            if not (isPrimitiveForBoxing inputType) then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "eco.box input should be primitive (i64, f64, i16, i1), got "
                            ++ typeToString inputType
                    }

            else if not (isEcoValueType resultType) then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "eco.box result should be !eco.value, got "
                            ++ typeToString resultType
                    }

            else
                Nothing

        _ ->
            -- Malformed op, skip (other tests may catch this)
            Nothing


{-| Check if a type is a valid primitive for boxing operations.

This includes i1 (Bool) which can be boxed/unboxed for control flow,
but is NOT allowed in heap/closure storage (checked by other tests).

-}
isPrimitiveForBoxing : MlirType -> Bool
isPrimitiveForBoxing t =
    case t of
        I1 ->
            True

        I16 ->
            True

        I64 ->
            True

        F64 ->
            True

        _ ->
            False


{-| Check a single eco.unbox operation.

eco.unbox must:

  - Have input operand of !eco.value type
  - Have result of primitive type (i64, f64, i16, or i1 for Bool)

-}
checkUnboxOp : MlirOp -> Maybe Violation
checkUnboxOp op =
    case ( extractOperandTypes op, extractResultTypes op ) of
        ( Just [ inputType ], [ resultType ] ) ->
            if not (isEcoValueType inputType) then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "eco.unbox input should be !eco.value, got "
                            ++ typeToString inputType
                    }

            else if not (isPrimitiveForBoxing resultType) then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "eco.unbox result should be primitive (i64, f64, i16, i1), got "
                            ++ typeToString resultType
                    }

            else
                Nothing

        _ ->
            -- Malformed op, skip
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
            "!" ++ name

        FunctionType _ ->
            "function"
