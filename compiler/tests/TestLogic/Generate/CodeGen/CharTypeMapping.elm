module TestLogic.Generate.CodeGen.CharTypeMapping exposing (expectCharTypeMapping)

{-| Checks that the ops converting between `Char` and `Int` in the MLIR
generated for a program give the `Char` side the type `i16`, so that a
conversion emitted with some other width is caught.

The code generator's type for a `Char` is `i16`
(`Compiler.Generate.MLIR.Types.ecoChar`). The ops that convert between a `Char`
and an `Int` are where that width meets the `i64` of an `Int`, and they are what
this module inspects. An op's operand types are read from its `_operand_types`
attribute, the list of operand types the code generator records on an op.

Among the ops whose names start with `eco.char.`, a violation is reported for:

  - an `eco.char.toInt` whose first recorded operand type is not `i16`;
  - an `eco.char.fromInt` whose first result type is not `i16`.

Among what is not checked: every other `eco.char.` op, including the
comparisons; a `Char` constant; a case on a `Char`; the `Int` side of either
conversion; and an `eco.char.toInt` with no `_operand_types` attribute.

@docs expectCharTypeMapping

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractOperandTypes
        , extractResultTypes
        , findOpsWithPrefix
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Creates an expectation that `srcModule` compiles to MLIR and that its
`eco.char.toInt` operands and `eco.char.fromInt` results are `i16`.

The expectation fails with the test pipeline's error message, prefixed
`Compilation failed:`, if compilation fails. When several ops break the rule,
the failure reports only the first of them.

-}
expectCharTypeMapping : Src.Module -> Expectation
expectCharTypeMapping srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCharTypeMapping mlirModule)


{-| Returns a violation for each op of `mlirModule`, at any depth, whose name
starts with `eco.char.` and that `checkCharOp` rejects.
-}
checkCharTypeMapping : MlirModule -> List Violation
checkCharTypeMapping mlirModule =
    let
        charOps =
            findOpsWithPrefix "eco.char." mlirModule
    in
    List.filterMap checkCharOp charOps


{-| Returns a violation if `op` is an `eco.char.toInt` whose first recorded
operand type is not `i16`, or an `eco.char.fromInt` whose first result type is
not `i16`.

An `eco.char.toInt` without the `_operand_types` attribute, or with an empty
one, and an `eco.char.fromInt` with no result pass. Any other op passes.

-}
checkCharOp : MlirOp -> Maybe Violation
checkCharOp op =
    case op.name of
        "eco.char.toInt" ->
            case extractOperandTypes op of
                Just (operandType :: _) ->
                    if operandType /= I16 then
                        Just
                            { opId = op.id
                            , opName = op.name
                            , message = "eco.char.toInt operand should be i16, got " ++ typeToString operandType
                            }

                    else
                        Nothing

                _ ->
                    Nothing

        "eco.char.fromInt" ->
            let
                resultTypes =
                    extractResultTypes op
            in
            case List.head resultTypes of
                Just resultType ->
                    if resultType /= I16 then
                        Just
                            { opId = op.id
                            , opName = op.name
                            , message = "eco.char.fromInt result should be i16, got " ++ typeToString resultType
                            }

                    else
                        Nothing

                Nothing ->
                    Nothing

        _ ->
            Nothing


{-| Returns the MLIR spelling of an integer or float type, as in `i16`, for use
in a violation message. A named struct gives its bare name, without the leading
`!`, and a function type gives the word `function`.
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
            name

        FunctionType _ ->
            "function"
