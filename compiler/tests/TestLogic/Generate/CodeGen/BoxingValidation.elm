module TestLogic.Generate.CodeGen.BoxingValidation exposing (expectBoxingValidation)

{-| The code generator moves a value between its primitive and its boxed form
with two ops, `eco.box` and `eco.unbox`, and no type in `Mlir.Mlir` stops it
emitting one with the wrong type on either side. This module checks the
generated MLIR for such an op.

A _boxed_ value has type `!eco.value`. A _primitive_, here, is a value of type
`i64`, `f64`, `i16` or `i1`, the unboxed form of an Int, a Float, a Char or a
Bool. `i1` is accepted because a Bool is `i1` in SSA operand context, such as
the scrutinee of a case, and is unboxed to `i1` to get there. Where a Bool may
be held as `i1` is not checked here.

`expectBoxingValidation` compiles a source module to MLIR and looks at every
`eco.box` and `eco.unbox` op in the result. A violation is:

  - an `eco.box` whose operand is not a primitive, or whose result is not
    `!eco.value`;
  - an `eco.unbox` whose operand is not `!eco.value`, or whose result is not a
    primitive.

The operand type checked is the one the op records in its `_operand_types`
attribute, as `TestLogic.Generate.CodeGen.Invariants` describes, not the type
of the value the operand names.

Among what is not checked: an op that does not record exactly one operand type,
or that does not have exactly one result, is skipped without a violation.

@docs expectBoxingValidation

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
        , isEcoValueType
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that compiles `srcModule` to MLIR with
`TestLogic.TestPipeline.runToMlir` and passes when no `eco.box` or `eco.unbox`
op in the result is a violation. An `eco.box` must take `i64`, `f64`, `i16` or
`i1` and produce `!eco.value`; an `eco.unbox` must take `!eco.value` and
produce one of those four types. Ops that do not record exactly one operand
type in `_operand_types`, or that do not have exactly one result, are skipped.

It fails with the compiler's message if compilation fails, and otherwise with
the first violation, as `TestLogic.Generate.CodeGen.Invariants.violationsToExpectation`
describes.

-}
expectBoxingValidation : Src.Module -> Expectation
expectBoxingValidation srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkBoxingValidation mlirModule)


{-| Returns the violations among the `eco.box` and `eco.unbox` ops of
`mlirModule`, those of `eco.box` ops first.
-}
checkBoxingValidation : MlirModule -> List Violation
checkBoxingValidation mlirModule =
    let
        boxOps =
            findOpsNamed "eco.box" mlirModule

        unboxOps =
            findOpsNamed "eco.unbox" mlirModule

        boxViolations =
            List.filterMap checkBoxOp boxOps

        unboxViolations =
            List.filterMap checkUnboxOp unboxOps
    in
    boxViolations ++ unboxViolations


{-| Returns a violation if `op`, an `eco.box`, has an operand type that is not
a primitive or a result that is not `!eco.value`. The operand is checked first,
so an op wrong on both sides gives one violation, about its operand.

Returns `Nothing` when `op` does not record exactly one operand type or does
not have exactly one result.

-}
checkBoxOp : MlirOp -> Maybe Violation
checkBoxOp op =
    case ( extractOperandTypes op, extractResultTypes op ) of
        ( Just [ inputType ], [ resultType ] ) ->
            if not (isPrimitiveForBoxing inputType) then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "eco.box input should be primitive (i64, f64, i16, i1), got "
                            ++ typeToString inputType
                    }

            else if not (isEcoValueType resultType) then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "eco.box result should be !eco.value, got "
                            ++ typeToString resultType
                    }

            else
                Nothing

        _ ->
            Nothing


{-| Returns whether `t` is `i1`, `i16`, `i64` or `f64`, the types an `eco.box`
may take and an `eco.unbox` may produce.
-}
isPrimitiveForBoxing : MlirType -> Bool
isPrimitiveForBoxing t =
    case t of
        I1 ->
            True

        I16 ->
            True

        I64 ->
            True

        F64 ->
            True

        _ ->
            False


{-| Returns a violation if `op`, an `eco.unbox`, has an operand type that is not
`!eco.value` or a result that is not a primitive. The operand is checked first,
so an op wrong on both sides gives one violation, about its operand.

Returns `Nothing` when `op` does not record exactly one operand type or does
not have exactly one result.

-}
checkUnboxOp : MlirOp -> Maybe Violation
checkUnboxOp op =
    case ( extractOperandTypes op, extractResultTypes op ) of
        ( Just [ inputType ], [ resultType ] ) ->
            if not (isEcoValueType inputType) then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "eco.unbox input should be !eco.value, got "
                            ++ typeToString inputType
                    }

            else if not (isPrimitiveForBoxing resultType) then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "eco.unbox result should be primitive (i64, f64, i16, i1), got "
                            ++ typeToString resultType
                    }

            else
                Nothing

        _ ->
            Nothing


{-| Returns the text of `t` for a violation message: the MLIR name of an integer
or float type, `!` followed by the name of a named type, or the word `function`
for a function type.
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
