module TestLogic.Generate.CodeGen.CEcoValueLowering exposing (expectCEcoValueLowering)

{-| A type variable that monomorphization leaves with the `CEcoValue`
constraint stands for a value that is always boxed, and code generation is
expected to give it the MLIR type `!eco.value` (see `Constraint` in
`Compiler.AST.Monomorphized`). The checker here is named for that rule, but
as written it checks only that the program compiles to MLIR.

The expectation compiles a program and picks out the `eco.call` ops whose
callee name contains `Debug` or `debug`. For those whose callee name also
contains `log`, it reads the operand types from the `_operand_types` attribute
and passes every one after the first to `checkPolymorphicOperands`; for those
whose callee name contains `toString` instead, it passes every one. That
function reports no violations for any input, so nothing found along the way
can fail the expectation.

An MLIR operand type on its own does not say whether the argument's type was a
type variable or a concrete type such as `Int`. The monomorphized graph is
passed to `checkCEcoValueLowering`, but it is not read.

@docs expectCEcoValueLowering

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractOperandTypes
        , findOpsNamed
        , getStringAttr
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that compiles `srcModule` to MLIR with
`TestLogic.TestPipeline.runToMlir` and applies the `Debug` call check to the
result.

The check reports no violations, so the expectation fails only when compilation
fails, with `Compilation failed:` followed by the pipeline's message.

-}
expectCEcoValueLowering : Src.Module -> Expectation
expectCEcoValueLowering srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule, monoGraph } ->
            violationsToExpectation (checkCEcoValueLowering mlirModule monoGraph)


{-| Returns the violations found in the operands of the `Debug` calls in
`mlirModule`, which is always none, because `checkPolymorphicOperands` reports
none. The `MonoGraph` argument is not read.
-}
checkCEcoValueLowering : MlirModule -> Mono.MonoGraph -> List Violation
checkCEcoValueLowering mlirModule _ =
    let
        callOps =
            findOpsNamed "eco.call" mlirModule

        debugCalls =
            List.filter isDebugCall callOps
    in
    List.concatMap checkDebugCallOperands debugCalls


{-| Returns whether the `callee` attribute of `op` contains `Debug` or `debug`.
This is a substring match on the callee's name, so it accepts any callee whose
name contains either word. An op with no string or symbol `callee` is not
accepted.
-}
isDebugCall : MlirOp -> Bool
isDebugCall op =
    case getStringAttr "callee" op of
        Just callee ->
            String.contains "Debug" callee || String.contains "debug" callee

        Nothing ->
            False


{-| Returns the violations in the operands of one `Debug` call, as judged by
`checkPolymorphicOperands`, which reports none.

When the callee's name contains `log`, every operand type after the first is
passed on. Otherwise, when the name contains `toString`, every operand type is
passed on. Any other callee, and an op without an `_operand_types` attribute,
gives no violations.

-}
checkDebugCallOperands : MlirOp -> List Violation
checkDebugCallOperands op =
    case getStringAttr "callee" op of
        Just callee ->
            case extractOperandTypes op of
                Just operandTypes ->
                    if String.contains "log" callee then
                        checkPolymorphicOperands op callee (List.drop 1 operandTypes)

                    else if String.contains "toString" callee then
                        checkPolymorphicOperands op callee operandTypes

                    else
                        []

                Nothing ->
                    []

        Nothing ->
            []


{-| Returns no violations, whatever the call, its callee name and the operand
types it is given. None of its arguments is examined.
-}
checkPolymorphicOperands : MlirOp -> String -> List MlirType -> List Violation
checkPolymorphicOperands _ _ _ =
    []
