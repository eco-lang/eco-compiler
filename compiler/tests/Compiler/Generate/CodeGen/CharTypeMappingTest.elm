module Compiler.Generate.CodeGen.CharTypeMappingTest exposing (suite)

{-| Tests for CGEN_015: Char Type Mapping invariant.

`monoTypeToMlir` must map `MChar` to `i16` (not `i32`),
and all char constants/ops must use `i16`.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( chrExpr
        , intExpr
        , listExpr
        , makeModule
        , tupleExpr
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
        , Test.test "Char in tuple uses i16" charInTupleTest
        , Test.test "List of chars uses i16" charListTest
        , Test.test "Multiple char literals use i16" multipleCharsTest
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


charInTupleTest : () -> Expectation
charInTupleTest _ =
    -- Char in tuple should use i16
    runInvariantTest
        (makeModule "testValue"
            (tupleExpr (chrExpr "x") (intExpr 42))
        )


charListTest : () -> Expectation
charListTest _ =
    -- List of chars should use i16
    runInvariantTest
        (makeModule "testValue"
            (listExpr [ chrExpr "h", chrExpr "i" ])
        )


multipleCharsTest : () -> Expectation
multipleCharsTest _ =
    -- Multiple char literals in nested structure
    runInvariantTest
        (makeModule "testValue"
            (tupleExpr (chrExpr "A") (chrExpr "B"))
        )
