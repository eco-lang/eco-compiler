module TestLogic.Generate.CodeGen.TupleProjection exposing (expectTupleProjection)

{-| Test logic for CGEN\_022: Tuple Projection invariant.

Tuple destructuring must use `eco.project.tuple2` or `eco.project.tuple3`
with valid field indices.

@docs expectTupleProjection

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


{-| Verify that tuple projection invariants hold for a source module.
-}
expectTupleProjection : Src.Module -> Expectation
expectTupleProjection srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkTupleProjection mlirModule)


{-| Check tuple projection invariants.
-}
checkTupleProjection : MlirModule -> List Violation
checkTupleProjection mlirModule =
    let
        tuple2Ops =
            findOpsNamed "eco.project.tuple2" mlirModule

        tuple2Violations =
            List.filterMap (checkTupleOp 2) tuple2Ops

        tuple3Ops =
            findOpsNamed "eco.project.tuple3" mlirModule

        tuple3Violations =
            List.filterMap (checkTupleOp 3) tuple3Ops
    in
    tuple2Violations ++ tuple3Violations


checkTupleOp : Int -> MlirOp -> Maybe Violation
checkTupleOp tupleSize op =
    let
        maybeField =
            getIntAttr "field" op

        operandCount =
            List.length op.operands

        resultCount =
            List.length op.results

        maxField =
            tupleSize - 1

        tupleName =
            "eco.project.tuple" ++ String.fromInt tupleSize
    in
    case maybeField of
        Nothing ->
            Just
                { opId = op.id
                , opName = op.name
                , message = tupleName ++ " missing field attribute"
                }

        Just field ->
            if field < 0 || field > maxField then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        tupleName
                            ++ " field="
                            ++ String.fromInt field
                            ++ " out of range [0,"
                            ++ String.fromInt maxField
                            ++ "]"
                    }

            else if operandCount /= 1 then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = tupleName ++ " should have exactly 1 operand, got " ++ String.fromInt operandCount
                    }

            else if resultCount /= 1 then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = tupleName ++ " should have exactly 1 result, got " ++ String.fromInt resultCount
                    }

            else
                Nothing
