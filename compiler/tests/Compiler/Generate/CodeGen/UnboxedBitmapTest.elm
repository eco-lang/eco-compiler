module Compiler.Generate.CodeGen.UnboxedBitmapTest exposing (suite)

{-| Tests for CGEN_026 and CGEN_027: Unboxed Bitmap Consistency invariants.

CGEN_026: For container construct ops, bit N of `unboxed_bitmap` must be set
iff operand N is a primitive type.

CGEN_027: For `eco.construct.list`, `head_unboxed` must be true iff head
operand is primitive.

-}

import Bitwise
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , floatExpr
        , intExpr
        , listExpr
        , makeModule
        , recordExpr
        , strExpr
        , tupleExpr
        , varExpr
        )
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractOperandTypes
        , findOpsNamed
        , getBoolAttr
        , getIntAttr
        , isPrimitiveType
        , violationsToExpectation
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_026/027: Unboxed Bitmap Consistency"
        [ -- CGEN_026: Container bitmap tests
          Test.test "Tuple with int fields has correct bitmap" tupleIntBitmapTest
        , Test.test "Tuple with mixed types has correct bitmap" tupleMixedBitmapTest
        , Test.test "Record with int field has correct bitmap" recordIntBitmapTest
        , Test.test "Record with mixed types has correct bitmap" recordMixedBitmapTest

        -- CGEN_027: List head_unboxed tests
        , Test.test "List of int has head_unboxed=true" listIntHeadUnboxedTest
        , Test.test "List of string has head_unboxed=false" listStringHeadUnboxedTest
        ]



-- INVARIANT CHECKER


{-| Check unboxed bitmap consistency for containers (CGEN_026).
-}
checkUnboxedBitmap : MlirModule -> List Violation
checkUnboxedBitmap mlirModule =
    let
        tuple2Ops =
            findOpsNamed "eco.construct.tuple2" mlirModule

        tuple3Ops =
            findOpsNamed "eco.construct.tuple3" mlirModule

        recordOps =
            findOpsNamed "eco.construct.record" mlirModule

        customOps =
            findOpsNamed "eco.construct.custom" mlirModule

        targetOps =
            tuple2Ops ++ tuple3Ops ++ recordOps ++ customOps

        containerViolations =
            List.concatMap checkContainerBitmap targetOps

        -- CGEN_027: Check list head_unboxed
        listOps =
            findOpsNamed "eco.construct.list" mlirModule

        listViolations =
            List.filterMap checkListHeadUnboxed listOps
    in
    containerViolations ++ listViolations


checkContainerBitmap : MlirOp -> List Violation
checkContainerBitmap op =
    let
        unboxedBitmap =
            getIntAttr "unboxed_bitmap" op |> Maybe.withDefault 0

        maybeOperandTypes =
            extractOperandTypes op
    in
    case maybeOperandTypes of
        Nothing ->
            -- Can't verify without _operand_types
            []

        Just operandTypes ->
            List.indexedMap (checkBitmapBit op unboxedBitmap) operandTypes
                |> List.filterMap identity


checkBitmapBit : MlirOp -> Int -> Int -> MlirType -> Maybe Violation
checkBitmapBit op bitmap index operandType =
    let
        bitIsSet =
            Bitwise.and bitmap (Bitwise.shiftLeftBy index 1) /= 0

        typeIsPrimitive =
            isPrimitiveType operandType
    in
    if bitIsSet && not typeIsPrimitive then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                "unboxed_bitmap bit "
                    ++ String.fromInt index
                    ++ " is set but operand type is "
                    ++ typeToString operandType
                    ++ ", expected primitive"
            }

    else if not bitIsSet && typeIsPrimitive then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                "unboxed_bitmap bit "
                    ++ String.fromInt index
                    ++ " is clear but operand type is "
                    ++ typeToString operandType
                    ++ ", expected !eco.value"
            }

    else
        Nothing


checkListHeadUnboxed : MlirOp -> Maybe Violation
checkListHeadUnboxed op =
    let
        headUnboxed =
            getBoolAttr "head_unboxed" op |> Maybe.withDefault False

        maybeOperandTypes =
            extractOperandTypes op
    in
    case maybeOperandTypes of
        Nothing ->
            -- Can't verify
            Nothing

        Just [] ->
            -- No operands
            Nothing

        Just (headType :: _) ->
            let
                headIsPrimitive =
                    isPrimitiveType headType
            in
            if headUnboxed && not headIsPrimitive then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "head_unboxed=true but head type is "
                            ++ typeToString headType
                            ++ ", expected primitive"
                    }

            else if not headUnboxed && headIsPrimitive then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "head_unboxed=false but head type is "
                            ++ typeToString headType
                            ++ ", expected !eco.value"
                    }

            else
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
            violationsToExpectation (checkUnboxedBitmap mlirModule)



-- TEST CASES


tupleIntBitmapTest : () -> Expectation
tupleIntBitmapTest _ =
    runInvariantTest (makeModule "testValue" (tupleExpr (intExpr 1) (intExpr 2)))


tupleMixedBitmapTest : () -> Expectation
tupleMixedBitmapTest _ =
    runInvariantTest (makeModule "testValue" (tupleExpr (intExpr 1) (strExpr "hello")))


recordIntBitmapTest : () -> Expectation
recordIntBitmapTest _ =
    runInvariantTest
        (makeModule "testValue"
            (recordExpr [ ( "x", intExpr 1 ), ( "y", intExpr 2 ) ])
        )


recordMixedBitmapTest : () -> Expectation
recordMixedBitmapTest _ =
    runInvariantTest
        (makeModule "testValue"
            (recordExpr [ ( "count", intExpr 1 ), ( "name", strExpr "test" ) ])
        )


listIntHeadUnboxedTest : () -> Expectation
listIntHeadUnboxedTest _ =
    runInvariantTest (makeModule "testValue" (listExpr [ intExpr 1, intExpr 2, intExpr 3 ]))


listStringHeadUnboxedTest : () -> Expectation
listStringHeadUnboxedTest _ =
    runInvariantTest (makeModule "testValue" (listExpr [ strExpr "a", strExpr "b" ]))
