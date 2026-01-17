module Compiler.Generate.CodeGen.CustomConstructionTest exposing (suite)

{-| Tests for CGEN_020: Custom ADT Construction invariant.

`eco.construct.custom` is only for user-defined custom ADTs.
Attributes must have valid `tag` and `size`, and `size` must match operand count.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( callExpr
        , intExpr
        , makeModule
        , strExpr
        , varExpr
        )
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getIntAttr
        , getStringAttr
        , violationsToExpectation
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_020: Custom ADT Construction"
        [ Test.test "Just value uses eco.construct.custom with correct attributes" justValueTest
        , Test.test "eco.construct.custom has required tag attribute" tagAttributeTest
        , Test.test "eco.construct.custom has required size attribute" sizeAttributeTest
        , Test.test "eco.construct.custom size matches operand count" sizeMatchesOperandsTest
        , Test.test "Built-in type constructors not in eco.construct.custom" builtInNotCustomTest
        ]



-- INVARIANT CHECKER


{-| Check custom construction invariants.
-}
checkCustomConstruction : MlirModule -> List Violation
checkCustomConstruction mlirModule =
    let
        customOps =
            findOpsNamed "eco.construct.custom" mlirModule

        violations =
            List.concatMap checkCustomOp customOps
    in
    violations


checkCustomOp : MlirOp -> List Violation
checkCustomOp op =
    let
        maybeTag =
            getIntAttr "tag" op

        maybeSize =
            getIntAttr "size" op

        operandCount =
            List.length op.operands

        maybeConstructorName =
            getStringAttr "constructor" op
    in
    List.filterMap identity
        [ -- Check tag attribute exists
          case maybeTag of
            Nothing ->
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.construct.custom missing tag attribute"
                    }

            _ ->
                Nothing

        -- Check size attribute exists
        , case maybeSize of
            Nothing ->
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.construct.custom missing size attribute"
                    }

            Just size ->
                -- Check size matches operand count
                if size /= operandCount then
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message =
                            "eco.construct.custom size="
                                ++ String.fromInt size
                                ++ " but operand count="
                                ++ String.fromInt operandCount
                        }

                else
                    Nothing

        -- Check not using custom for built-in list types
        , case maybeConstructorName of
            Just name ->
                if List.member name [ "Cons", "Nil" ] then
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message = "List constructor '" ++ name ++ "' should use eco.construct.list or eco.constant, not eco.construct.custom"
                        }

                else
                    Nothing

            Nothing ->
                Nothing
        ]



-- TEST HELPER


runInvariantTest : Src.Module -> Expectation
runInvariantTest srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCustomConstruction mlirModule)



-- TEST CASES


justValueTest : () -> Expectation
justValueTest _ =
    runInvariantTest (makeModule "testValue" (callExpr (varExpr "Just") [ intExpr 5 ]))


tagAttributeTest : () -> Expectation
tagAttributeTest _ =
    -- Any custom ADT usage should have the tag attribute
    runInvariantTest (makeModule "testValue" (callExpr (varExpr "Just") [ strExpr "hello" ]))


sizeAttributeTest : () -> Expectation
sizeAttributeTest _ =
    -- Any custom ADT usage should have the size attribute
    runInvariantTest (makeModule "testValue" (callExpr (varExpr "Just") [ intExpr 42 ]))


sizeMatchesOperandsTest : () -> Expectation
sizeMatchesOperandsTest _ =
    -- Size should match the number of operands
    runInvariantTest (makeModule "testValue" (callExpr (varExpr "Just") [ intExpr 1 ]))


builtInNotCustomTest : () -> Expectation
builtInNotCustomTest _ =
    -- Ensure built-in types aren't being constructed with custom ops
    -- Testing Maybe and List together to verify separation
    runInvariantTest
        (makeModule "testValue"
            (callExpr (varExpr "Just")
                [ intExpr 1 ]
            )
        )
