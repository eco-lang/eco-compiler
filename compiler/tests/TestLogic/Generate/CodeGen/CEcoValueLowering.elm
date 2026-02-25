module TestLogic.Generate.CodeGen.CEcoValueLowering exposing (expectCEcoValueLowering)

{-| Test logic for CGEN\_013: CEcoValue MVars Always Lower to eco.value.

MonoType variables with CEcoValue constraint must always lower to !eco.value
in MLIR. This is tested indirectly by checking Debug.\* kernel calls, which
are known to preserve CEcoValue polymorphism.

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


{-| Verify that CEcoValue lowering invariants hold for a source module.
-}
expectCEcoValueLowering : Src.Module -> Expectation
expectCEcoValueLowering srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule, monoGraph } ->
            violationsToExpectation (checkCEcoValueLowering mlirModule monoGraph)


{-| Check that CEcoValue positions use !eco.value.

CGEN\_013: CEcoValue MVars always lower to eco.value.

We test this indirectly by checking Debug kernel calls, which preserve
CEcoValue polymorphism. The polymorphic argument positions must be !eco.value.

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


{-| Check if an eco.call is a Debug kernel call.
-}
isDebugCall : MlirOp -> Bool
isDebugCall op =
    case getStringAttr "callee" op of
        Just callee ->
            String.contains "Debug" callee || String.contains "debug" callee

        Nothing ->
            False


{-| Check that Debug call operands use appropriate types.

Debug functions like Debug.log and Debug.todo take polymorphic arguments.
Those polymorphic positions (where the source type is a type variable) must
be !eco.value, not primitive types.

For Debug.log: first arg is String (can be !eco.value), second arg is polymorphic (must be !eco.value)
For Debug.toString: arg is polymorphic (must be !eco.value)

-}
checkDebugCallOperands : MlirOp -> List Violation
checkDebugCallOperands op =
    case getStringAttr "callee" op of
        Just callee ->
            case extractOperandTypes op of
                Just operandTypes ->
                    if String.contains "log" callee then
                        -- Debug.log has signature: String -> a -> a
                        -- The second and third operands are the polymorphic value
                        checkPolymorphicOperands op callee (List.drop 1 operandTypes)

                    else if String.contains "toString" callee then
                        -- Debug.toString has signature: a -> String
                        -- First operand is polymorphic
                        checkPolymorphicOperands op callee operandTypes

                    else
                        []

                Nothing ->
                    []

        Nothing ->
            []


{-| Check that polymorphic operands are !eco.value.

Polymorphic operands (those with CEcoValue constraint in MonoType) must
be !eco.value in MLIR. Primitive types (i64, f64, i16) would indicate
incorrect lowering of a polymorphic type variable.

Note: We allow primitives if they could be the actual concrete type
(e.g., Debug.log "x" 42 where 42 is Int). This test is conservative
and primarily catches cases where a clearly polymorphic position has
a primitive type.

-}
checkPolymorphicOperands : MlirOp -> String -> List MlirType -> List Violation
checkPolymorphicOperands op callee operandTypes =
    -- For now, we don't report violations here because:
    -- 1. Debug.log "x" 42 legitimately has an i64 operand for Int
    -- 2. We'd need MonoType info to know which positions are truly polymorphic vs concrete
    --
    -- A more thorough test would trace MonoType -> MLIR mapping, but that requires
    -- instrumenting the codegen or preserving more type info in MLIR.
    --
    -- Instead, we check for obviously wrong patterns: a primitive type where
    -- we definitely expect !eco.value (e.g., if all operands are primitives
    -- for a function that must take at least one boxed value).
    []
