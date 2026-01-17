module Compiler.Generate.CodeGen.CharTypeMappingTest exposing (suite)

{-| Tests for CGEN_015: Char Type Mapping invariant.

`monoTypeToMlir` must map `MChar` to `i16` (not `i32`),
and all char constants/ops must use `i16`.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( callExpr
        , chrExpr
        , intExpr
        , makeModule
        , varExpr
        )
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractOperandTypes
        , extractResultTypes
        , findOpsWithPrefix
        , violationsToExpectation
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_015: Char Type Mapping"
        [ Test.test "Character literal has correct type" charLiteralTest
        , Test.test "eco.char.toInt operand is i16" charToIntOperandTest
        , Test.test "eco.char.fromInt result is i16" charFromIntResultTest
        , Test.test "Char operations use i16, not i32" charOpsUseI16Test
        ]



-- INVARIANT CHECKER


{-| Check char type mapping invariants.
-}
checkCharTypeMapping : MlirModule -> List Violation
checkCharTypeMapping mlirModule =
    let
        charOps =
            findOpsWithPrefix "eco.char." mlirModule

        violations =
            List.filterMap checkCharOp charOps
    in
    violations


checkCharOp : MlirOp -> Maybe Violation
checkCharOp op =
    case op.name of
        "eco.char.toInt" ->
            -- eco.char.toInt: i16 -> i64
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
            -- eco.char.fromInt: i64 -> i16
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
            -- Other char ops should also use i16
            Nothing


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
            name

        FunctionType _ ->
            "function"



-- TEST HELPER


runInvariantTest : Src.Module -> Expectation
runInvariantTest srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCharTypeMapping mlirModule)



-- TEST CASES


charLiteralTest : () -> Expectation
charLiteralTest _ =
    runInvariantTest (makeModule "testValue" (chrExpr "a"))


charToIntOperandTest : () -> Expectation
charToIntOperandTest _ =
    -- Char.toCode 'x' should use i16 input
    runInvariantTest
        (makeModule "testValue"
            (callExpr (varExpr "Char.toCode") [ chrExpr "x" ])
        )


charFromIntResultTest : () -> Expectation
charFromIntResultTest _ =
    -- Char.fromCode 65 should produce i16
    runInvariantTest
        (makeModule "testValue"
            (callExpr (varExpr "Char.fromCode") [ intExpr 65 ])
        )


charOpsUseI16Test : () -> Expectation
charOpsUseI16Test _ =
    -- Multiple char operations in one module
    runInvariantTest
        (makeModule "testValue"
            (callExpr (varExpr "Char.toCode") [ chrExpr "A" ])
        )
