module TestLogic.Generate.CodeGen.BooleanConstants exposing (expectBooleanConstants)

{-| Checks how a Bool is represented in generated MLIR, so that a Bool recorded
as a raw `i1` operand of an op that builds a heap object (`eco.construct.*`) or
a closure (`eco.papCreate`) fails a test instead of going unnoticed.

A Bool has two representations in the MLIR the code generator emits. In SSA
operand context it is `i1`, a one-bit integer, which is what an `eco.case`
with `case_kind` `"bool"` branches on. In a heap object, in a closure capture
and at a function boundary it is `!eco.value`, a boxed value.
`Compiler.Generate.MLIR.Types` decides which representation applies where.

`expectBooleanConstants` compiles a program to MLIR and fails when it finds
either of two kinds of violation, showing the first one found:

  - An `eco.constant` op whose `value` attribute, a string or a symbol
    reference, is `"True"` or `"False"` and whose one result is not
    `!eco.value`.
  - An `eco.construct.*` or `eco.papCreate` op with `i1` among the types listed
    in its `_operand_types` attribute.

Among what is not checked: an op with no `_operand_types` attribute; the
operands of `eco.papExtend`, `eco.papCreateGroup`, `eco.to_heap`, `eco.call`
and any other op; an `i1` used anywhere else; and an `eco.constant` with no
result or more than one. The `eco.constant` ops that `Compiler.Generate.MLIR.Ops`
builds carry an integer `kind` attribute and no `value` attribute, so none of
them is counted as a Bool constant.

@docs expectBooleanConstants

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractOperandTypes
        , extractResultTypes
        , findOpsNamed
        , getStringAttr
        , isEcoValueType
        , violationsToExpectation
        , walkAllOps
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Compiles `srcModule` to MLIR with `TestLogic.TestPipeline.runToMlir` and
passes when the result has none of the violations the module docstring lists.

Fails with `Compilation failed:` and the pipeline's error when an earlier stage
fails.

-}
expectBooleanConstants : Src.Module -> Expectation
expectBooleanConstants srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkBooleanConstants mlirModule)


{-| Returns the violations in `mlirModule`: first each Bool `eco.constant` whose
result is not `!eco.value`, then each `i1` in the `_operand_types` of an
`eco.construct.*` or `eco.papCreate` op.
-}
checkBooleanConstants : MlirModule -> List Violation
checkBooleanConstants mlirModule =
    let
        constantOps =
            findOpsNamed "eco.constant" mlirModule

        boolConstants =
            List.filter isBoolConstant constantOps

        constantViolations =
            List.filterMap checkBoolConstantType boolConstants

        i1Violations =
            checkI1Usage mlirModule
    in
    constantViolations ++ i1Violations


{-| Returns whether `op`'s `value` attribute, a string or a symbol reference, is
`"True"` or `"False"`. Other attributes, including an integer `kind`, are not
looked at.
-}
isBoolConstant : MlirOp -> Bool
isBoolConstant op =
    case getStringAttr "value" op of
        Just "True" ->
            True

        Just "False" ->
            True

        _ ->
            False


{-| Returns a violation when `op` has exactly one result and its type is not
`!eco.value`. An op with no result or several results gives `Nothing`.
-}
checkBoolConstantType : MlirOp -> Maybe Violation
checkBoolConstantType op =
    case extractResultTypes op of
        [ resultType ] ->
            if not (isEcoValueType resultType) then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "Bool constant must produce !eco.value, got "
                            ++ typeToString resultType
                    }

            else
                Nothing

        _ ->
            Nothing


{-| Returns a violation for each `i1` recorded in the `_operand_types` attribute
of an `eco.construct.*` op, which builds a heap object, and then of an
`eco.papCreate` op, which builds a closure. No other op is examined.
-}
checkI1Usage : MlirModule -> List Violation
checkI1Usage mlirModule =
    let
        allOps =
            walkAllOps mlirModule

        constructOps =
            List.filter isConstructOp allOps

        constructViolations =
            List.concatMap checkNoI1Operands constructOps

        papCreateOps =
            List.filter (\op -> op.name == "eco.papCreate") allOps

        papViolations =
            List.concatMap checkNoI1Operands papCreateOps
    in
    constructViolations ++ papViolations


{-| Returns whether `op`'s name starts with `eco.construct.`.
-}
isConstructOp : MlirOp -> Bool
isConstructOp op =
    String.startsWith "eco.construct." op.name


{-| Returns a violation for each `i1` among the types in `op`'s `_operand_types`
attribute, or none when the attribute is absent.

An entry of that attribute that is not a type attribute is dropped before the
entries are numbered, so the operand index in a message counts type entries
only.

-}
checkNoI1Operands : MlirOp -> List Violation
checkNoI1Operands op =
    case extractOperandTypes op of
        Just operandTypes ->
            List.indexedMap (checkNotI1 op) operandTypes
                |> List.filterMap identity

        Nothing ->
            []


{-| Returns a violation against `op` when `operandType` is `i1`, naming the
operand by `index`, its zero-based position.
-}
checkNotI1 : MlirOp -> Int -> MlirType -> Maybe Violation
checkNotI1 op index operandType =
    if operandType == I1 then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                "operand "
                    ++ String.fromInt index
                    ++ " is i1 (Bool) but must be !eco.value at heap/closure boundary"
            }

    else
        Nothing


{-| Returns a short name for `t` for a violation message: the MLIR spelling of
an integer or float type, `!` followed by the name of a named struct, and
`function` for any function type.
-}
typeToString : MlirType -> String
typeToString t =
    case t of
        I1 ->
            "i1"

        I8 ->
            "i8"

        I16 ->
            "i16"

        I32 ->
            "i32"

        I64 ->
            "i64"

        F64 ->
            "f64"

        NamedStruct name ->
            "!" ++ name

        FunctionType _ ->
            "function"
