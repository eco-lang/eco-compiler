module TestLogic.Generate.CodeGen.RecordConstruction exposing (expectRecordConstruction, checkRecordConstruction)

{-| Test logic for CGEN\_018: Record Construction invariant.

Non-empty records must use `eco.construct.record`;
empty records must use `eco.constant EmptyRec`.

@docs expectRecordConstruction, checkRecordConstruction

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import TestLogic.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getIntAttr
        , violationsToExpectation
        )


{-| Verify that record construction invariants hold for a source module.

This compiles the module to MLIR and checks:

  - eco.construct.record has required field\_count attribute
  - field\_count is non-zero (use eco.constant EmptyRec for empty records)
  - field\_count matches operand count

-}
expectRecordConstruction : Src.Module -> Expectation
expectRecordConstruction srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkRecordConstruction mlirModule)


{-| Check record construction invariants.
-}
checkRecordConstruction : MlirModule -> List Violation
checkRecordConstruction mlirModule =
    let
        recordOps =
            findOpsNamed "eco.construct.record" mlirModule

        recordViolations =
            List.filterMap checkRecordOp recordOps
    in
    recordViolations


checkRecordOp : MlirOp -> Maybe Violation
checkRecordOp op =
    let
        maybeFieldCount =
            getIntAttr "field_count" op

        operandCount =
            List.length op.operands
    in
    case maybeFieldCount of
        Nothing ->
            Just
                { opId = op.id
                , opName = op.name
                , message = "eco.construct.record missing field_count attribute"
                }

        Just 0 ->
            Just
                { opId = op.id
                , opName = op.name
                , message = "eco.construct.record with field_count=0, should use eco.constant EmptyRec"
                }

        Just fieldCount ->
            if fieldCount /= operandCount then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "eco.construct.record field_count ("
                            ++ String.fromInt fieldCount
                            ++ ") doesn't match operand count ("
                            ++ String.fromInt operandCount
                            ++ ")"
                    }

            else
                Nothing
