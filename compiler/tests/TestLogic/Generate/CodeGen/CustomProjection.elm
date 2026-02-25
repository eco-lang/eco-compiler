module TestLogic.Generate.CodeGen.CustomProjection exposing (expectCustomProjection, checkCustomProjection)

{-| Test logic for CGEN\_024: Custom ADT Projection invariant.

Custom ADT field access must use `eco.project.custom` with valid field index.

@docs expectCustomProjection, checkCustomProjection

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getIntAttr
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Verify that custom projection invariants hold for a source module.
-}
expectCustomProjection : Src.Module -> Expectation
expectCustomProjection srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCustomProjection mlirModule)


{-| Check custom projection invariants.
-}
checkCustomProjection : MlirModule -> List Violation
checkCustomProjection mlirModule =
    let
        customProjectOps =
            findOpsNamed "eco.project.custom" mlirModule

        violations =
            List.filterMap checkCustomProjectOp customProjectOps
    in
    violations


checkCustomProjectOp : MlirOp -> Maybe Violation
checkCustomProjectOp op =
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
                , message = "eco.project.custom missing field_index attribute"
                }

        Just fieldIndex ->
            if fieldIndex < 0 then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.project.custom field_index=" ++ String.fromInt fieldIndex ++ " is negative"
                    }

            else if operandCount /= 1 then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.project.custom should have exactly 1 operand, got " ++ String.fromInt operandCount
                    }

            else if resultCount /= 1 then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.project.custom should have exactly 1 result, got " ++ String.fromInt resultCount
                    }

            else
                Nothing
