module TestLogic.Generate.CodeGen.TupleConstruction exposing
    ( expectTupleConstruction
    , checkTupleConstruction
    )

{-| Test logic for CGEN_017: Tuple Construction invariant.

Tuples must use `eco.construct.tuple2` or `eco.construct.tuple3`;
never `eco.construct.custom`.

@docs expectTupleConstruction, checkTupleConstruction

-}

import Compiler.AST.Source as Src
import TestLogic.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getStringAttr
        , violationsToExpectation
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)


{-| Verify that tuple construction invariants hold for a source module.

This compiles the module to MLIR and checks:

  - eco.construct.tuple2 has exactly 2 operands
  - eco.construct.tuple3 has exactly 3 operands
  - eco.construct.custom is never used for tuple constructors

-}
expectTupleConstruction : Src.Module -> Expectation
expectTupleConstruction srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkTupleConstruction mlirModule)


{-| Check tuple construction invariants on an MlirModule.
-}
checkTupleConstruction : MlirModule -> List Violation
checkTupleConstruction mlirModule =
    let
        -- Check tuple2 operand count
        tuple2Ops =
            findOpsNamed "eco.construct.tuple2" mlirModule

        tuple2Violations =
            List.filterMap checkTuple2OperandCount tuple2Ops

        -- Check tuple3 operand count
        tuple3Ops =
            findOpsNamed "eco.construct.tuple3" mlirModule

        tuple3Violations =
            List.filterMap checkTuple3OperandCount tuple3Ops

        -- Check for tuple misuse in eco.construct.custom
        customOps =
            findOpsNamed "eco.construct.custom" mlirModule

        customViolations =
            List.filterMap checkForTupleConstructorMisuse customOps
    in
    tuple2Violations ++ tuple3Violations ++ customViolations


checkTuple2OperandCount : MlirOp -> Maybe Violation
checkTuple2OperandCount op =
    let
        operandCount =
            List.length op.operands
    in
    if operandCount /= 2 then
        Just
            { opId = op.id
            , opName = op.name
            , message = "eco.construct.tuple2 should have exactly 2 operands, got " ++ String.fromInt operandCount
            }

    else
        Nothing


checkTuple3OperandCount : MlirOp -> Maybe Violation
checkTuple3OperandCount op =
    let
        operandCount =
            List.length op.operands
    in
    if operandCount /= 3 then
        Just
            { opId = op.id
            , opName = op.name
            , message = "eco.construct.tuple3 should have exactly 3 operands, got " ++ String.fromInt operandCount
            }

    else
        Nothing


checkForTupleConstructorMisuse : MlirOp -> Maybe Violation
checkForTupleConstructorMisuse op =
    let
        constructorName =
            getStringAttr "constructor" op
    in
    case constructorName of
        Just name ->
            if isTupleConstructorName name then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.construct.custom used for tuple constructor '" ++ name ++ "', should use eco.construct.tuple2 or tuple3"
                    }

            else
                Nothing

        Nothing ->
            Nothing


isTupleConstructorName : String -> Bool
isTupleConstructorName name =
    List.member name [ "Tuple2", "Tuple3", "(,)", "(,,)" ]
