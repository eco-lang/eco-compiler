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

The operand type checked is the _defined_ type of the value the operand names:
the type of the op result or block argument that introduces it within the
enclosing top-level op (`TestLogic.Generate.CodeGen.Invariants.typeEnvOfOp`),
not the type the op records in its `_operand_types` attribute. An op that does
not have exactly one operand and one result, or whose operand has no
definition in its top-level op, is a violation too.

@docs expectBoxingValidation

-}

import Compiler.AST.Source as Src
import Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( TypeEnv
        , Violation
        , extractResultTypes
        , isEcoValueType
        , typeEnvOfOp
        , violationsToExpectation
        , walkOpAndChildren
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that compiles `srcModule` to MLIR with
`TestLogic.TestPipeline.runToMlir` and passes when no `eco.box` or `eco.unbox`
op in the result is a violation. An `eco.box` must take `i64`, `f64`, `i16` or
`i1` and produce `!eco.value`; an `eco.unbox` must take `!eco.value` and
produce one of those four types, the operand's type being the defined type
of the value it names.

It fails with the compiler's message if compilation fails, and otherwise with
the violations, as `TestLogic.Generate.CodeGen.Invariants.violationsToExpectation`
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
`mlirModule`, top-level op by top-level op.
-}
checkBoxingValidation : MlirModule -> List Violation
checkBoxingValidation mlirModule =
    List.concatMap
        (\topOp ->
            let
                env =
                    typeEnvOfOp topOp
            in
            walkOpAndChildren topOp
                |> List.filterMap
                    (\op ->
                        if op.name == "eco.box" then
                            checkConversion env op isPrimitiveForBoxing "primitive (i64, f64, i16, i1)" isEcoValueType "!eco.value"

                        else if op.name == "eco.unbox" then
                            checkConversion env op isEcoValueType "!eco.value" isPrimitiveForBoxing "primitive (i64, f64, i16, i1)"

                        else
                            Nothing
                    )
        )
        mlirModule.body


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


{-| Returns a violation if `op`, an `eco.box` or `eco.unbox`, does not have
exactly one operand and one result, if its operand has no defined type in
`env`, or if the operand's defined type or the result type is not of the kind
the op requires. The operand is checked before the result.
-}
checkConversion : TypeEnv -> MlirOp -> (MlirType -> Bool) -> String -> (MlirType -> Bool) -> String -> Maybe Violation
checkConversion env op inputOk inputDesc resultOk resultDesc =
    let
        violation message =
            Just { opId = op.id, opName = op.name, message = message }
    in
    case ( op.operands, extractResultTypes op ) of
        ( [ operand ], [ resultType ] ) ->
            case Dict.get operand env of
                Nothing ->
                    violation (op.name ++ " operand " ++ operand ++ " has no definition in its function")

                Just inputType ->
                    if not (inputOk inputType) then
                        violation (op.name ++ " input should be " ++ inputDesc ++ ", got " ++ typeToString inputType)

                    else if not (resultOk resultType) then
                        violation (op.name ++ " result should be " ++ resultDesc ++ ", got " ++ typeToString resultType)

                    else
                        Nothing

        _ ->
            violation (op.name ++ " should have exactly one operand and one result")


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
