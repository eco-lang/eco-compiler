module SourceIR.KernelOperatorCases exposing (expectSuite)

{-| Kernel operator tests — binops that resolve to kernel calls.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder exposing (binopsExpr, define, floatExpr, intExpr, letExpr, listExpr, makeKernelModule, qualVarExpr, varExpr)
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Kernel operators " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Arithmetic operators", run = arithmeticOps expectFn }
    , { label = "Float division", run = \_ -> expectFn (makeKernelModule "testValue" (binopsExpr [ ( floatExpr 10.0, "/" ) ] (floatExpr 3.0))) }
    , { label = "Integer division", run = \_ -> expectFn (makeKernelModule "testValue" (binopsExpr [ ( intExpr 10, "//" ) ] (intExpr 3))) }
    , { label = "Power operator", run = \_ -> expectFn (makeKernelModule "testValue" (binopsExpr [ ( intExpr 2, "^" ) ] (intExpr 10))) }
    , { label = "Pipe operator", run = \_ -> expectFn (makeKernelModule "testValue" (binopsExpr [ ( intExpr 5, "|>" ) ] (qualVarExpr "Elm.Kernel.Basics" "abs"))) }
    , { label = ":: cons operator", run = \_ -> expectFn (makeKernelModule "testValue" (binopsExpr [ ( intExpr 0, "::" ) ] (listExpr [ intExpr 1, intExpr 2 ]))) }
    , { label = "++ append operator", run = \_ -> expectFn (makeKernelModule "testValue" (binopsExpr [ ( listExpr [ intExpr 1 ], "++" ) ] (listExpr [ intExpr 2 ]))) }
    ]


arithmeticOps : (Src.Module -> Expectation) -> (() -> Expectation)
arithmeticOps expectFn _ =
    expectFn (makeKernelModule "testValue"
        (letExpr
            [ define "a" [] (binopsExpr [ ( intExpr 3, "+" ) ] (intExpr 4))
            , define "b" [] (binopsExpr [ ( intExpr 10, "-" ) ] (intExpr 3))
            , define "c" [] (binopsExpr [ ( intExpr 6, "*" ) ] (intExpr 7))
            ]
            (binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c"))
        ))
