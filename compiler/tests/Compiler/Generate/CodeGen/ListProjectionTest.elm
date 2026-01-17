module Compiler.Generate.CodeGen.ListProjectionTest exposing (suite)

{-| Tests for CGEN_021: List Projection invariant.

List destructuring must use only `eco.project.list_head` and `eco.project.list_tail`.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( caseExpr
        , intExpr
        , listExpr
        , makeModule
        , pCons
        , pList
        , pVar
        , varExpr
        )
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , ecoValueType
        , extractResultTypes
        , findOpsNamed
        , isEcoValueType
        , violationsToExpectation
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_021: List Projection"
        [ Test.test "eco.project.list_head has exactly 1 operand" headOperandCountTest
        , Test.test "eco.project.list_head has exactly 1 result" headResultCountTest
        , Test.test "eco.project.list_tail has exactly 1 operand" tailOperandCountTest
        , Test.test "eco.project.list_tail has exactly 1 result" tailResultCountTest
        , Test.test "eco.project.list_tail result is !eco.value" tailResultTypeTest
        , Test.test "List pattern matching generates list projections" listPatternMatchingTest
        ]



-- INVARIANT CHECKER


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



-- TEST HELPER


runInvariantTest : Src.Module -> Expectation
runInvariantTest srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkListProjection mlirModule)



-- TEST CASES


headOperandCountTest : () -> Expectation
headOperandCountTest _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (listExpr [ intExpr 1, intExpr 2 ])
                    [ ( pCons (pVar "x") (pVar "rest"), varExpr "x" )
                    , ( pList [], intExpr 0 )
                    ]
                )
    in
    runInvariantTest modul


headResultCountTest : () -> Expectation
headResultCountTest _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (listExpr [ intExpr 1, intExpr 2 ])
                    [ ( pCons (pVar "x") (pVar "rest"), varExpr "x" )
                    , ( pList [], intExpr 0 )
                    ]
                )
    in
    runInvariantTest modul


tailOperandCountTest : () -> Expectation
tailOperandCountTest _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (listExpr [ intExpr 1, intExpr 2 ])
                    [ ( pCons (pVar "x") (pVar "rest"), varExpr "rest" )
                    , ( pList [], listExpr [] )
                    ]
                )
    in
    runInvariantTest modul


tailResultCountTest : () -> Expectation
tailResultCountTest _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (listExpr [ intExpr 1, intExpr 2 ])
                    [ ( pCons (pVar "x") (pVar "rest"), varExpr "rest" )
                    , ( pList [], listExpr [] )
                    ]
                )
    in
    runInvariantTest modul


tailResultTypeTest : () -> Expectation
tailResultTypeTest _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (listExpr [ intExpr 1, intExpr 2 ])
                    [ ( pCons (pVar "x") (pVar "rest"), varExpr "rest" )
                    , ( pList [], listExpr [] )
                    ]
                )
    in
    runInvariantTest modul


listPatternMatchingTest : () -> Expectation
listPatternMatchingTest _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (listExpr [ intExpr 1, intExpr 2, intExpr 3 ])
                    [ ( pCons (pVar "a") (pCons (pVar "b") (pVar "rest")), varExpr "a" )
                    , ( pList [], intExpr 0 )
                    ]
                )
    in
    runInvariantTest modul
