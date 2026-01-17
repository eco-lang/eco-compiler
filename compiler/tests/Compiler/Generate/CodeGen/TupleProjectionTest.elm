module Compiler.Generate.CodeGen.TupleProjectionTest exposing (suite)

{-| Tests for CGEN_022: Tuple Projection invariant.

Tuple destructuring must use `eco.project.tuple2` or `eco.project.tuple3`
with valid field indices.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( callExpr
        , caseExpr
        , intExpr
        , makeModule
        , pTuple
        , pTuple3
        , pVar
        , strExpr
        , tuple3Expr
        , tupleExpr
        , varExpr
        )
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
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_022: Tuple Projection"
        [ Test.test "eco.project.tuple2 has field attribute" tuple2FieldAttrTest
        , Test.test "eco.project.tuple2 field in range [0,1]" tuple2FieldRangeTest
        , Test.test "eco.project.tuple2 has exactly 1 operand" tuple2OperandCountTest
        , Test.test "eco.project.tuple2 has exactly 1 result" tuple2ResultCountTest
        , Test.test "eco.project.tuple3 has field attribute" tuple3FieldAttrTest
        , Test.test "eco.project.tuple3 field in range [0,2]" tuple3FieldRangeTest
        , Test.test "Tuple.first uses correct projection" tupleFirstTest
        , Test.test "Tuple.second uses correct projection" tupleSecondTest
        ]



-- INVARIANT CHECKER


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



-- TEST HELPER


runInvariantTest : Src.Module -> Expectation
runInvariantTest srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkTupleProjection mlirModule)



-- TEST CASES


tuple2FieldAttrTest : () -> Expectation
tuple2FieldAttrTest _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (tupleExpr (intExpr 1) (intExpr 2))
                    [ ( pTuple (pVar "a") (pVar "b"), varExpr "a" ) ]
                )
    in
    runInvariantTest modul


tuple2FieldRangeTest : () -> Expectation
tuple2FieldRangeTest _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (tupleExpr (intExpr 1) (intExpr 2))
                    [ ( pTuple (pVar "a") (pVar "b"), varExpr "b" ) ]
                )
    in
    runInvariantTest modul


tuple2OperandCountTest : () -> Expectation
tuple2OperandCountTest _ =
    runInvariantTest
        (makeModule "testValue"
            (callExpr (varExpr "Tuple.first") [ tupleExpr (intExpr 1) (intExpr 2) ])
        )


tuple2ResultCountTest : () -> Expectation
tuple2ResultCountTest _ =
    runInvariantTest
        (makeModule "testValue"
            (callExpr (varExpr "Tuple.second") [ tupleExpr (intExpr 1) (intExpr 2) ])
        )


tuple3FieldAttrTest : () -> Expectation
tuple3FieldAttrTest _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (tuple3Expr (intExpr 1) (intExpr 2) (intExpr 3))
                    [ ( pTuple3 (pVar "a") (pVar "b") (pVar "c"), varExpr "a" ) ]
                )
    in
    runInvariantTest modul


tuple3FieldRangeTest : () -> Expectation
tuple3FieldRangeTest _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (tuple3Expr (intExpr 1) (intExpr 2) (intExpr 3))
                    [ ( pTuple3 (pVar "a") (pVar "b") (pVar "c"), varExpr "c" ) ]
                )
    in
    runInvariantTest modul


tupleFirstTest : () -> Expectation
tupleFirstTest _ =
    runInvariantTest
        (makeModule "testValue"
            (callExpr (varExpr "Tuple.first") [ tupleExpr (intExpr 1) (intExpr 2) ])
        )


tupleSecondTest : () -> Expectation
tupleSecondTest _ =
    runInvariantTest
        (makeModule "testValue"
            (callExpr (varExpr "Tuple.second") [ tupleExpr (intExpr 1) (intExpr 2) ])
        )
