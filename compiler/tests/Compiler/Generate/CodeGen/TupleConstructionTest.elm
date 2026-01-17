module Compiler.Generate.CodeGen.TupleConstructionTest exposing (suite)

{-| Tests for CGEN_017: Tuple Construction invariant.

Tuples must use `eco.construct.tuple2` or `eco.construct.tuple3`;
never `eco.construct.custom`.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( intExpr
        , makeModule
        , strExpr
        , tuple3Expr
        , tupleExpr
        )
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getStringAttr
        , violationsToExpectation
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_017: Tuple Construction"
        [ Test.test "2-tuple uses eco.construct.tuple2" tuple2Test
        , Test.test "3-tuple uses eco.construct.tuple3" tuple3Test
        , Test.test "Nested 2-tuple uses eco.construct.tuple2" nestedTuple2Test
        , Test.test "eco.construct.tuple2 has exactly 2 operands" tuple2OperandCountTest
        , Test.test "eco.construct.tuple3 has exactly 3 operands" tuple3OperandCountTest
        , Test.test "No tuple constructors in eco.construct.custom" noCustomTupleConstructorsTest
        ]



-- INVARIANT CHECKER


{-| Check tuple construction invariants.
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



-- TEST HELPER


runInvariantTest : Src.Module -> Expectation
runInvariantTest srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkTupleConstruction mlirModule)



-- TEST CASES


tuple2Test : () -> Expectation
tuple2Test _ =
    runInvariantTest (makeModule "testValue" (tupleExpr (intExpr 1) (intExpr 2)))


tuple3Test : () -> Expectation
tuple3Test _ =
    runInvariantTest (makeModule "testValue" (tuple3Expr (intExpr 1) (intExpr 2) (intExpr 3)))


nestedTuple2Test : () -> Expectation
nestedTuple2Test _ =
    let
        inner =
            tupleExpr (intExpr 1) (intExpr 2)

        modul =
            makeModule "testValue"
                (tupleExpr inner (intExpr 3))
    in
    runInvariantTest modul


tuple2OperandCountTest : () -> Expectation
tuple2OperandCountTest _ =
    runInvariantTest (makeModule "testValue" (tupleExpr (intExpr 1) (intExpr 2)))


tuple3OperandCountTest : () -> Expectation
tuple3OperandCountTest _ =
    runInvariantTest (makeModule "testValue" (tuple3Expr (intExpr 1) (intExpr 2) (intExpr 3)))


noCustomTupleConstructorsTest : () -> Expectation
noCustomTupleConstructorsTest _ =
    let
        pair =
            tupleExpr (intExpr 1) (intExpr 2)

        triple =
            tuple3Expr (intExpr 3) (intExpr 4) (intExpr 5)
    in
    runInvariantTest
        (makeModule "testValue"
            (tupleExpr pair triple)
        )
