module Compiler.Generate.CodeGen.OperandTypesAttr exposing
    ( expectOperandTypesAttr
    , checkOperandTypesAttr
    )

{-| Test logic for CGEN_032: Operand Types Attribute invariant.

`_operand_types` is required when an op has operands and must have correct length.

@docs expectOperandTypesAttr, checkOperandTypesAttr

-}

import Compiler.AST.Source as Src
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


{-| Verify that operand types attribute invariants hold for a source module.
-}
expectOperandTypesAttr : Src.Module -> Expectation
expectOperandTypesAttr srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkOperandTypesAttr mlirModule)


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
