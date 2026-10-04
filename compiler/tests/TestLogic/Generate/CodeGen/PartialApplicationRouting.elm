module TestLogic.Generate.CodeGen.PartialApplicationRouting exposing (expectPartialApplicationRouting)

{-| A call that supplies fewer arguments than its function takes must build a
closure (`eco.papCreate`) or add arguments to one (`eco.papExtend`), not be
emitted as an `eco.call`. This module is meant to catch an `eco.call` that
does so.

`expectPartialApplicationRouting` compiles a program to MLIR and reports each
`eco.call` with exactly one result whose type is an MLIR `FunctionType`.

The check cannot tell an under-saturated call from a saturated call that
returns a function, but in practice neither is reported: the code generator
gives a function value the type `!eco.value` (`Compiler.Generate.MLIR.Types`),
so an `eco.call` that returns a function has an `!eco.value` result. As things
stand `expectPartialApplicationRouting` passes whenever compilation succeeds.

Among what is not tested: calls with no result or several results, and whether
an `eco.call` supplies as many arguments as its callee takes.

@docs expectPartialApplicationRouting

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractResultTypes
        , findOpsNamed
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that passes when `srcModule` compiles to MLIR with
`runToMlir` and no single-result `eco.call` in the result has a `FunctionType`
result.

A failed compilation fails with its error. Otherwise only the first violation
found is reported, as `violationsToExpectation` describes.

-}
expectPartialApplicationRouting : Src.Module -> Expectation
expectPartialApplicationRouting srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkPartialApplicationRouting mlirModule)


{-| Returns a violation for each `eco.call` op in `mlirModule`, at any depth,
that has a single result of `FunctionType`.
-}
checkPartialApplicationRouting : MlirModule -> List Violation
checkPartialApplicationRouting mlirModule =
    let
        callOps =
            findOpsNamed "eco.call" mlirModule
    in
    List.filterMap checkCallResultType callOps


{-| Returns a violation if `op` has exactly one result and its type is a
`FunctionType`. An op with no result or several results is not checked.
-}
checkCallResultType : MlirOp -> Maybe Violation
checkCallResultType op =
    case extractResultTypes op of
        [ resultType ] ->
            if isFunctionType resultType then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "eco.call produces function type "
                            ++ typeToString resultType
                            ++ " but partial applications must use eco.papCreate/papExtend. "
                            ++ "eco.call should only produce non-function results."
                    }

            else
                Nothing

        _ ->
            Nothing


{-| Returns whether `t` is an MLIR `FunctionType`.
-}
isFunctionType : MlirType -> Bool
isFunctionType t =
    case t of
        FunctionType _ ->
            True

        _ ->
            False


{-| Returns `t` written in the style of MLIR's textual syntax, for a violation
message. A named struct prints with a leading `!`, as in `!eco.value`.
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

        FunctionType { inputs, results } ->
            "("
                ++ String.join ", " (List.map typeToString inputs)
                ++ ") -> ("
                ++ String.join ", " (List.map typeToString results)
                ++ ")"
