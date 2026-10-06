module TestLogic.Generate.CodeGen.OperandTypesAttr exposing (expectOperandTypesAttr)

{-| Catches the code generator leaving out, or miscounting, the operand types
it records on certain eco ops.

An `MlirOp` holds its operands as SSA names, without their types. The code
generator records the types in the op's `_operand_types` attribute, an array
with one entry per operand, and several of the other MLIR checkers read operand
types only from there and skip an op that has none (see
`TestLogic.Generate.CodeGen.Invariants`). This module makes a missing or
miscounted attribute a failure, for the ops it names.

`expectOperandTypesAttr` compiles one source module to MLIR with
`TestLogic.TestPipeline.runToMlir`. For every op, at any depth, named in
`requiredOps` (the `eco.construct` ops for lists, two- and three-element tuples,
records and custom types, and `eco.call`, `eco.papCreate`, `eco.papExtend`,
`eco.return`, `eco.box` and `eco.unbox`) that has at least one operand, it
fails if `_operand_types` is absent or is not an array, or if the array's
length differs from the number of operands.

Among what is not tested: ops not named in `requiredOps`; whether each entry is
a type, or the right type for its operand; and MLIR produced by bootstrap
Stage 5 (the substitution engine), since `runToMlir` is the production
pipeline.

@docs expectOperandTypesAttr

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , getArrayAttr
        , violationsToExpectation
        , walkAllOps
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that compiles `srcModule` to MLIR and passes when
every op named in `requiredOps` that has operands carries an `_operand_types`
array with one entry per operand.

It fails with the pipeline's error message when compilation fails, and
otherwise with a message naming the first op that breaks the rule.

-}
expectOperandTypesAttr : Src.Module -> Expectation
expectOperandTypesAttr srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkOperandTypesAttr mlirModule)


{-| The names of the ops that must carry `_operand_types` whenever they have
at least one operand.
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


{-| Returns one violation for each op in `mlirModule`, at any depth, that is
named in `requiredOps` and fails `checkOperandTypesOp`.
-}
checkOperandTypesAttr : MlirModule -> List Violation
checkOperandTypesAttr mlirModule =
    let
        allOps =
            walkAllOps mlirModule

        targetOps =
            List.filter (\op -> List.member op.name requiredOps) allOps
    in
    List.filterMap checkOperandTypesOp targetOps


{-| Returns a violation when `op` has operands and its `_operand_types` array
is absent or has a different number of entries, and `Nothing` otherwise. An
`_operand_types` attribute that is not an array counts as absent.
-}
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
