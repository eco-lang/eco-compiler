module SourceIR.KernelComparisonCases exposing (expectSuite)

{-| Kernel comparison tests — comparison operators that resolve to kernel calls.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder exposing (binopsExpr, boolExpr, chrExpr, define, floatExpr, intExpr, letExpr, makeKernelModule, strExpr, varExpr)
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Kernel comparisons " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Int comparison operators", run = intComparisons expectFn }
    , { label = "Float comparison op", run = \_ -> expectFn (makeKernelModule "testValue" (binopsExpr [ ( floatExpr 1.5, "<" ) ] (floatExpr 2.5))) }
    , { label = "String equality op", run = \_ -> expectFn (makeKernelModule "testValue" (binopsExpr [ ( strExpr "hello", "==" ) ] (strExpr "world"))) }
    , { label = "Bool logical ops", run = boolLogicalOps expectFn }
    , { label = "Char equality op", run = \_ -> expectFn (makeKernelModule "testValue" (binopsExpr [ ( chrExpr "a", "==" ) ] (chrExpr "b"))) }
    ]


intComparisons : (Src.Module -> Expectation) -> (() -> Expectation)
intComparisons expectFn _ =
    expectFn (makeKernelModule "testValue"
        (letExpr
            [ define "lt" [] (binopsExpr [ ( intExpr 1, "<" ) ] (intExpr 2))
            , define "gt" [] (binopsExpr [ ( intExpr 2, ">" ) ] (intExpr 1))
            , define "le" [] (binopsExpr [ ( intExpr 1, "<=" ) ] (intExpr 1))
            , define "ge" [] (binopsExpr [ ( intExpr 1, ">=" ) ] (intExpr 1))
            , define "eq" [] (binopsExpr [ ( intExpr 1, "==" ) ] (intExpr 1))
            , define "ne" [] (binopsExpr [ ( intExpr 1, "/=" ) ] (intExpr 2))
            ]
            (varExpr "lt")
        ))


boolLogicalOps : (Src.Module -> Expectation) -> (() -> Expectation)
boolLogicalOps expectFn _ =
    expectFn (makeKernelModule "testValue"
        (letExpr
            [ define "a" [] (binopsExpr [ ( boolExpr True, "&&" ) ] (boolExpr False))
            , define "b" [] (binopsExpr [ ( boolExpr True, "||" ) ] (boolExpr False))
            ]
            (varExpr "a")
        ))
