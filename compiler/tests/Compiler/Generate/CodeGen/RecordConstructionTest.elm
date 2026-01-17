module Compiler.Generate.CodeGen.RecordConstructionTest exposing (suite)

{-| Tests for CGEN_018: Record Construction invariant.

Non-empty records must use `eco.construct.record`;
empty records must use `eco.constant EmptyRec`.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( intExpr
        , makeModule
        , recordExpr
        , strExpr
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
    Test.describe "CGEN_018: Record Construction"
        [ Test.test "Empty record uses eco.constant EmptyRec" emptyRecordTest
        , Test.test "Single field record uses eco.construct.record" singleFieldRecordTest
        , Test.test "Multi-field record uses eco.construct.record" multiFieldRecordTest
        , Test.test "eco.construct.record has matching field_count and operand count" fieldCountMatchesOperandsTest
        , Test.test "eco.construct.record has non-zero field_count" nonZeroFieldCountTest
        ]



-- INVARIANT CHECKER


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



-- TEST HELPER


runInvariantTest : Src.Module -> Expectation
runInvariantTest srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkRecordConstruction mlirModule)



-- TEST CASES


emptyRecordTest : () -> Expectation
emptyRecordTest _ =
    runInvariantTest (makeModule "testValue" (recordExpr []))


singleFieldRecordTest : () -> Expectation
singleFieldRecordTest _ =
    runInvariantTest (makeModule "testValue" (recordExpr [ ( "x", intExpr 1 ) ]))


multiFieldRecordTest : () -> Expectation
multiFieldRecordTest _ =
    runInvariantTest
        (makeModule "testValue"
            (recordExpr
                [ ( "x", intExpr 1 )
                , ( "y", intExpr 2 )
                , ( "z", intExpr 3 )
                ]
            )
        )


fieldCountMatchesOperandsTest : () -> Expectation
fieldCountMatchesOperandsTest _ =
    runInvariantTest
        (makeModule "testValue"
            (recordExpr
                [ ( "a", intExpr 1 )
                , ( "b", strExpr "hello" )
                ]
            )
        )


nonZeroFieldCountTest : () -> Expectation
nonZeroFieldCountTest _ =
    runInvariantTest
        (makeModule "testValue"
            (recordExpr [ ( "field", intExpr 42 ) ])
        )
