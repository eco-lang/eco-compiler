module Compiler.DeepFuzzTests exposing (expectSuite)

{-| Deep structural fuzz tests.

This module uses the type-safe fuzzers to generate structurally varied
Elm syntax for property-based testing. It follows the same pattern as
other test modules, taking an expectation function and condition string.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder exposing (makeModule)
import Compiler.Fuzz.Module as M
import Compiler.Fuzz.Structure as S exposing (BinopCategory(..))
import Compiler.Fuzz.TypedExpr as TE exposing (SimpleType(..), emptyScope)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Deep structural fuzz tests " ++ condStr)
        [ intExprTests expectFn condStr
        , floatExprTests expectFn condStr
        , stringExprTests expectFn condStr
        , boolExprTests expectFn condStr
        , containerTests expectFn condStr
        , structuralTests expectFn condStr
        , binopTests expectFn condStr
        , moduleTests expectFn condStr
        ]



-- =============================================================================
-- INT EXPRESSION TESTS
-- =============================================================================


intExprTests : (Src.Module -> Expectation) -> String -> Test
intExprTests expectFn condStr =
    Test.describe ("Random int expressions " ++ condStr)
        [ Test.fuzz (TE.intExprFuzzer (emptyScope 2))
            ("Shallow fuzzed int expression " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (TE.intExprFuzzer (emptyScope 3))
            ("Medium fuzzed int expression " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (TE.intExprFuzzer (emptyScope 4))
            ("Deep fuzzed int expression " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        ]



-- =============================================================================
-- FLOAT EXPRESSION TESTS
-- =============================================================================


floatExprTests : (Src.Module -> Expectation) -> String -> Test
floatExprTests expectFn condStr =
    Test.describe ("Random float expressions " ++ condStr)
        [ Test.fuzz (TE.floatExprFuzzer (emptyScope 2))
            ("Shallow fuzzed float expression " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (TE.floatExprFuzzer (emptyScope 3))
            ("Medium fuzzed float expression " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        ]



-- =============================================================================
-- STRING EXPRESSION TESTS
-- =============================================================================


stringExprTests : (Src.Module -> Expectation) -> String -> Test
stringExprTests expectFn condStr =
    Test.describe ("Random string expressions " ++ condStr)
        [ Test.fuzz (TE.stringExprFuzzer (emptyScope 2))
            ("Shallow fuzzed string expression " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (TE.stringExprFuzzer (emptyScope 3))
            ("Medium fuzzed string expression " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        ]



-- =============================================================================
-- BOOL EXPRESSION TESTS
-- =============================================================================


boolExprTests : (Src.Module -> Expectation) -> String -> Test
boolExprTests expectFn condStr =
    Test.describe ("Random bool expressions " ++ condStr)
        [ Test.fuzz (TE.boolExprFuzzer (emptyScope 2))
            ("Shallow fuzzed bool expression " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (TE.boolExprFuzzer (emptyScope 3))
            ("Medium fuzzed bool expression " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        ]



-- =============================================================================
-- CONTAINER EXPRESSION TESTS
-- =============================================================================


containerTests : (Src.Module -> Expectation) -> String -> Test
containerTests expectFn condStr =
    Test.describe ("Random container expressions " ++ condStr)
        [ Test.fuzz (TE.listExprFuzzer (emptyScope 2) TInt)
            ("List of int expression " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (TE.tupleExprFuzzer (emptyScope 2) TInt TString)
            ("Tuple expression " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (TE.tuple3ExprFuzzer (emptyScope 2) TInt TString TBool)
            ("3-tuple expression " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (TE.recordExprFuzzer (emptyScope 2) [ ( "x", TInt ), ( "y", TString ) ])
            ("Record expression " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (M.mixedContainerFuzzer (emptyScope 2))
            ("Mixed container expression " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        ]



-- =============================================================================
-- STRUCTURAL COMPLEXITY TESTS
-- =============================================================================


structuralTests : (Src.Module -> Expectation) -> String -> Test
structuralTests expectFn condStr =
    Test.describe ("Structural complexity tests " ++ condStr)
        [ Test.fuzz (S.multiBindingLetFuzzer (emptyScope 3) TInt)
            ("Multi-binding let expression " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (S.multiBranchCaseFuzzer (emptyScope 3) TInt TString)
            ("Multi-branch case expression " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (S.nestedLetFuzzer (emptyScope 4) TInt 3)
            ("Nested let expression " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (S.lambdaExprFuzzer (emptyScope 3) TInt)
            ("Lambda expression " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (M.complexExprFuzzer (emptyScope 3) TInt)
            ("Complex int expression " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        ]



-- =============================================================================
-- BINOP TESTS
-- =============================================================================


binopTests : (Src.Module -> Expectation) -> String -> Test
binopTests expectFn condStr =
    Test.describe ("Random binop expressions " ++ condStr)
        [ Test.fuzz (S.binopChainFuzzer (emptyScope 3) Arithmetic)
            ("Arithmetic binop chain " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (S.binopChainFuzzer (emptyScope 3) Boolean)
            ("Boolean binop chain " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (S.binopChainFuzzer (emptyScope 3) Comparison)
            ("Comparison binop chain " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (S.binopChainFuzzer (emptyScope 3) Equality)
            ("Equality binop chain " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (S.binopChainFuzzer (emptyScope 3) Append)
            ("Append binop chain " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        ]



-- =============================================================================
-- MODULE TESTS
-- =============================================================================


moduleTests : (Src.Module -> Expectation) -> String -> Test
moduleTests expectFn condStr =
    Test.describe ("Random module tests " ++ condStr)
        [ Test.fuzz (M.multiDefModuleFuzzer 2)
            ("Shallow multi-def module " ++ condStr)
            expectFn
        , Test.fuzz (M.multiDefModuleFuzzer 3)
            ("Medium multi-def module " ++ condStr)
            expectFn
        ]
