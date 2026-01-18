module Compiler.Generate.CodeGen.RecordProjection exposing
    ( expectRecordProjection
    , checkRecordProjection
    )

{-| Test logic for CGEN_023: Record Projection invariant.

Record field access must use `eco.project.record` with valid field index.

@docs expectRecordProjection, checkRecordProjection

-}

import Compiler.AST.Source as Src
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getIntAttr
        , violationsToExpectation
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)


{-| Verify that record projection invariants hold for a source module.
-}
expectRecordProjection : Src.Module -> Expectation
expectRecordProjection srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkRecordProjection mlirModule)


{-| Check record projection invariants.
-}
checkRecordProjection : MlirModule -> List Violation
checkRecordProjection mlirModule =
    let
        recordProjectOps =
            findOpsNamed "eco.project.record" mlirModule

        violations =
            List.filterMap checkRecordProjectOp recordProjectOps
    in
    violations


checkRecordProjectOp : MlirOp -> Maybe Violation
checkRecordProjectOp op =
    let
        maybeFieldIndex =
            getIntAttr "field_index" op

        operandCount =
            List.length op.operands

        resultCount =
            List.length op.results
    in
    case maybeFieldIndex of
        Nothing ->
            Just
                { opId = op.id
                , opName = op.name
                , message = "eco.project.record missing field_index attribute"
                }

        Just fieldIndex ->
            if fieldIndex < 0 then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.project.record field_index=" ++ String.fromInt fieldIndex ++ " is negative"
                    }

            else if operandCount /= 1 then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.project.record should have exactly 1 operand, got " ++ String.fromInt operandCount
                    }

            else if resultCount /= 1 then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.project.record should have exactly 1 result, got " ++ String.fromInt resultCount
                    }

            else
                Nothing
