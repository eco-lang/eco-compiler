module Compiler.Generate.CodeGen.OperandTypesAttrTest exposing (suite)

{-| Tests for CGEN_032: Operand Types Attribute invariant.

`_operand_types` is required when an op has operands and must have correct length.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( callExpr
        , intExpr
        , listExpr
        , makeModule
        , recordExpr
        , strExpr
        , tuple3Expr
        , tupleExpr
        , varExpr
        )
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , getArrayAttr
        , violationsToExpectation
        , walkAllOps
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_032: Operand Types Attribute"
        [ Test.test "eco.construct.list has _operand_types" listConstructOperandTypesTest
        , Test.test "eco.construct.tuple2 has _operand_types" tuple2OperandTypesTest
        , Test.test "eco.construct.record has _operand_types" recordOperandTypesTest
        , Test.test "eco.call has _operand_types" callOperandTypesTest
        , Test.test "_operand_types length matches operand count" operandTypesLengthTest
        ]



-- INVARIANT CHECKER


{-| Ops that require _operand_types when they have operands.
-}
requiredOps : List String
requiredOps =
    [ "eco.construct.list"
    , "eco.construct.tuple2"
    , "eco.construct.tuple3"
    , "eco.construct.record"
    , "eco.construct.custom"
    , "eco.call"
    , "eco.papCreate"
    , "eco.papExtend"
    , "eco.return"
    , "eco.box"
    , "eco.unbox"
    ]


{-| Check operand types attribute invariants.
-}
checkOperandTypesAttr : MlirModule -> List Violation
checkOperandTypesAttr mlirModule =
    let
        allOps =
            walkAllOps mlirModule

        targetOps =
            List.filter (\op -> List.member op.name requiredOps) allOps

        violations =
            List.filterMap checkOperandTypesOp targetOps
    in
    violations


checkOperandTypesOp : MlirOp -> Maybe Violation
checkOperandTypesOp op =
    let
        operandCount =
            List.length op.operands

        maybeOperandTypes =
            getArrayAttr "_operand_types" op
    in
    if operandCount == 0 then
        -- No operands, attribute not required
        Nothing

    else
        case maybeOperandTypes of
            Nothing ->
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        op.name
                            ++ " has "
                            ++ String.fromInt operandCount
                            ++ " operands but missing _operand_types"
                    }

            Just types ->
                let
                    typeCount =
                        List.length types
                in
                if typeCount /= operandCount then
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message =
                            op.name
                                ++ " has "
                                ++ String.fromInt operandCount
                                ++ " operands but _operand_types has "
                                ++ String.fromInt typeCount
                                ++ " entries"
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
            violationsToExpectation (checkOperandTypesAttr mlirModule)



-- TEST CASES


listConstructOperandTypesTest : () -> Expectation
listConstructOperandTypesTest _ =
    runInvariantTest (makeModule "testValue" (listExpr [ intExpr 1, intExpr 2 ]))


tuple2OperandTypesTest : () -> Expectation
tuple2OperandTypesTest _ =
    runInvariantTest (makeModule "testValue" (tupleExpr (intExpr 1) (intExpr 2)))


recordOperandTypesTest : () -> Expectation
recordOperandTypesTest _ =
    runInvariantTest
        (makeModule "testValue"
            (recordExpr [ ( "x", intExpr 1 ), ( "y", strExpr "hello" ) ])
        )


callOperandTypesTest : () -> Expectation
callOperandTypesTest _ =
    runInvariantTest (makeModule "testValue" (callExpr (varExpr "Just") [ intExpr 5 ]))


operandTypesLengthTest : () -> Expectation
operandTypesLengthTest _ =
    -- Multiple construction ops in one module
    let
        list =
            listExpr [ intExpr 1 ]

        record =
            recordExpr [ ( "a", intExpr 2 ) ]

        innerTuple =
            tuple3Expr (intExpr 3) (intExpr 4) (intExpr 5)
    in
    runInvariantTest
        (makeModule "testValue"
            (tuple3Expr list record innerTuple)
        )
