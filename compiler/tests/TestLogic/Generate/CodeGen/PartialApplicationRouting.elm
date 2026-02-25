module TestLogic.Generate.CodeGen.PartialApplicationRouting exposing (expectPartialApplicationRouting)

{-| Test logic for CGEN\_002: Partial Applications Through Closure Generation.

When a call produces a function-typed result (partial application), it must
go through eco.papCreate/eco.papExtend, not eco.call. eco.call should only
produce non-function results (fully saturated calls).

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


{-| Verify that partial applications are routed through closure generation.
-}
expectPartialApplicationRouting : Src.Module -> Expectation
expectPartialApplicationRouting srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkPartialApplicationRouting mlirModule)


{-| Check that eco.call never produces function-typed results.

CGEN\_002: Partial applications must go through eco.papCreate/papExtend.

Note: This checks that eco.call results are not function types. If a function
returns another function as its result (not a partial application), the callee
itself returns a closure, which is fine. This test catches cases where
generateCall incorrectly emits eco.call for undersaturated calls.

-}
checkPartialApplicationRouting : MlirModule -> List Violation
checkPartialApplicationRouting mlirModule =
    let
        callOps =
            findOpsNamed "eco.call" mlirModule
    in
    List.filterMap checkCallResultType callOps


{-| Check a single eco.call for function-typed result.
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
            -- Malformed or no-result call, skip
            Nothing


{-| Check if a type is a function type.
-}
isFunctionType : MlirType -> Bool
isFunctionType t =
    case t of
        FunctionType _ ->
            True

        _ ->
            False


typeToString : MlirType -> String
typeToString t =
    case t of
        I1 ->
            "i1"

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
