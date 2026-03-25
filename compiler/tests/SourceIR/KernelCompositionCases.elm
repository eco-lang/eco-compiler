module SourceIR.KernelCompositionCases exposing (expectSuite)

{-| Kernel composition tests — chained and multi-function kernel operations.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder exposing (binopsExpr, callExpr, intExpr, lambdaExpr, listExpr, makeKernelModule, pVar, qualVarExpr, varExpr)
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Kernel composition " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Chained List.map and List.reverse", run = chainedListOps expectFn }
    ]


chainedListOps : (Src.Module -> Expectation) -> (() -> Expectation)
chainedListOps expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.List" "reverse")
                [ callExpr (qualVarExpr "Elm.Kernel.List" "map")
                    [ lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2))
                    , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                    ]
                ]
            )
        )
