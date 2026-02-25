module TestLogic.Generate.CodeGen.ListProjection exposing (expectListProjection, checkListProjection)

{-| Test logic for CGEN\_021: List Projection invariant.

List destructuring must use only `eco.project.list_head` and `eco.project.list_tail`.

@docs expectListProjection, checkListProjection

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractResultTypes
        , findOpsNamed
        , isEcoValueType
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Verify that list projection invariants hold for a source module.
-}
expectListProjection : Src.Module -> Expectation
expectListProjection srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkListProjection mlirModule)


{-| Check list projection invariants.
-}
checkListProjection : MlirModule -> List Violation
checkListProjection mlirModule =
    let
        headOps =
            findOpsNamed "eco.project.list_head" mlirModule

        headViolations =
            List.filterMap checkListHeadOp headOps

        tailOps =
            findOpsNamed "eco.project.list_tail" mlirModule

        tailViolations =
            List.filterMap checkListTailOp tailOps
    in
    headViolations ++ tailViolations


checkListHeadOp : MlirOp -> Maybe Violation
checkListHeadOp op =
    let
        operandCount =
            List.length op.operands

        resultCount =
            List.length op.results
    in
    if operandCount /= 1 then
        Just
            { opId = op.id
            , opName = op.name
            , message = "eco.project.list_head should have exactly 1 operand, got " ++ String.fromInt operandCount
            }

    else if resultCount /= 1 then
        Just
            { opId = op.id
            , opName = op.name
            , message = "eco.project.list_head should have exactly 1 result, got " ++ String.fromInt resultCount
            }

    else
        Nothing


checkListTailOp : MlirOp -> Maybe Violation
checkListTailOp op =
    let
        operandCount =
            List.length op.operands

        resultCount =
            List.length op.results

        resultTypes =
            extractResultTypes op
    in
    if operandCount /= 1 then
        Just
            { opId = op.id
            , opName = op.name
            , message = "eco.project.list_tail should have exactly 1 operand, got " ++ String.fromInt operandCount
            }

    else if resultCount /= 1 then
        Just
            { opId = op.id
            , opName = op.name
            , message = "eco.project.list_tail should have exactly 1 result, got " ++ String.fromInt resultCount
            }

    else
        case List.head resultTypes of
            Just resultType ->
                if not (isEcoValueType resultType) then
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message = "eco.project.list_tail result should be !eco.value"
                        }

                else
                    Nothing

            Nothing ->
                Nothing
