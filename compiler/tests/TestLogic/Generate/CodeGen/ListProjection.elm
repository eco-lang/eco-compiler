module TestLogic.Generate.CodeGen.ListProjection exposing (expectListProjection)

{-| The eco MLIR dialect reads the parts of a cons cell with two operations:
`eco.project.list_head` gives the head and `eco.project.list_tail` gives the
tail. Each takes the cell as its one operand and gives one result. The tail is
itself a list, so its result must be `!eco.value`, the type of a boxed value.
This module checks that every such op in generated MLIR has that shape.

It compiles a source module to MLIR and looks at every op of the two names, at
any depth. An op is a violation when:

  - it has other than exactly one operand;
  - it has other than exactly one result;
  - it is an `eco.project.list_tail` whose result type is not `!eco.value`.

Among what is not checked:

  - the type of a head's result, which may be unboxed;
  - the type of either op's operand;
  - whether a list is ever taken apart by some other operation.

@docs expectListProjection

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


{-| Returns an expectation that every `eco.project.list_head` and
`eco.project.list_tail` op in the MLIR compiled from `srcModule` has exactly one
operand and one result, and that each `eco.project.list_tail` result is
`!eco.value`.

The module is compiled with `TestLogic.TestPipeline.runToMlir`. If compilation
fails, the expectation fails with the pipeline's message. If there are
violations, it fails with the message of the first one only, as
`violationsToExpectation` describes.

-}
expectListProjection : Src.Module -> Expectation
expectListProjection srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkListProjection mlirModule)


{-| Returns the violations of every `eco.project.list_head` op in `mlirModule`,
followed by those of every `eco.project.list_tail` op, at most one per op.
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


{-| Returns a violation when the `eco.project.list_head` op `op` has other than
one operand or, failing that, other than one result. Its result type is not
looked at.
-}
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


{-| Returns a violation when the `eco.project.list_tail` op `op` has other than
one operand, other than one result, or a result whose type is not
`!eco.value`, checked in that order, so an op reports only the first of these.
-}
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
