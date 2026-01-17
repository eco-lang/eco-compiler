module Compiler.Generate.CodeGen.RecordProjectionTest exposing (suite)

{-| Tests for CGEN_023: Record Projection invariant.

Record field access must use `eco.project.record` with valid field index.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( accessExpr
        , intExpr
        , makeModule
        , recordExpr
        , strExpr
        , tuple3Expr
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
    Test.describe "CGEN_023: Record Projection"
        [ Test.test "eco.project.record has field_index attribute" fieldIndexAttrTest
        , Test.test "eco.project.record field_index is non-negative" fieldIndexNonNegativeTest
        , Test.test "eco.project.record has exactly 1 operand" operandCountTest
        , Test.test "eco.project.record has exactly 1 result" resultCountTest
        , Test.test "Record field access uses correct projection" fieldAccessTest
        , Test.test "Multiple field accesses use correct projections" multiFieldAccessTest
        ]



-- INVARIANT CHECKER


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



-- TEST HELPER


runInvariantTest : Src.Module -> Expectation
runInvariantTest srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkRecordProjection mlirModule)



-- TEST CASES


fieldIndexAttrTest : () -> Expectation
fieldIndexAttrTest _ =
    runInvariantTest
        (makeModule "testValue"
            (accessExpr (recordExpr [ ( "x", intExpr 1 ) ]) "x")
        )


fieldIndexNonNegativeTest : () -> Expectation
fieldIndexNonNegativeTest _ =
    runInvariantTest
        (makeModule "testValue"
            (accessExpr
                (recordExpr [ ( "a", intExpr 1 ), ( "b", intExpr 2 ) ])
                "b"
            )
        )


operandCountTest : () -> Expectation
operandCountTest _ =
    runInvariantTest
        (makeModule "testValue"
            (accessExpr (recordExpr [ ( "field", intExpr 42 ) ]) "field")
        )


resultCountTest : () -> Expectation
resultCountTest _ =
    runInvariantTest
        (makeModule "testValue"
            (accessExpr (recordExpr [ ( "value", strExpr "hello" ) ]) "value")
        )


fieldAccessTest : () -> Expectation
fieldAccessTest _ =
    runInvariantTest
        (makeModule "testValue"
            (accessExpr
                (recordExpr [ ( "x", intExpr 1 ), ( "y", intExpr 2 ) ])
                "x"
            )
        )


multiFieldAccessTest : () -> Expectation
multiFieldAccessTest _ =
    let
        rec =
            recordExpr [ ( "a", intExpr 1 ), ( "b", intExpr 2 ), ( "c", intExpr 3 ) ]

        modul =
            makeModule "testValue"
                (tuple3Expr
                    (accessExpr rec "a")
                    (accessExpr rec "b")
                    (accessExpr rec "c")
                )
    in
    runInvariantTest modul
