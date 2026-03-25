module SourceIR.KernelContextCases exposing (expectSuite)

{-| Kernel context tests — kernel calls in lambda, let, nested call contexts.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder exposing (callExpr, define, intExpr, lambdaExpr, letExpr, makeKernelModule, pVar, qualVarExpr, varExpr)
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Kernel context " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Kernel in lambda", run = kernelInLambda expectFn }
    , { label = "Kernel in let binding", run = kernelInLetBinding expectFn }
    , { label = "Kernel nested calls", run = kernelNestedCalls expectFn }
    , { label = "Kernel chained arithmetic", run = kernelChainedArith expectFn }
    ]


kernelInLambda : (Src.Module -> Expectation) -> (() -> Expectation)
kernelInLambda expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (lambdaExpr [ pVar "x" ]
                (callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ varExpr "x", intExpr 1 ])
            )
        )


kernelInLetBinding : (Src.Module -> Expectation) -> (() -> Expectation)
kernelInLetBinding expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (letExpr
                [ define "result" [] (callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ intExpr 3, intExpr 4 ]) ]
                (varExpr "result")
            )
        )


kernelNestedCalls : (Src.Module -> Expectation) -> (() -> Expectation)
kernelNestedCalls expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.Basics" "add")
                [ callExpr (qualVarExpr "Elm.Kernel.Basics" "mul") [ intExpr 2, intExpr 3 ]
                , callExpr (qualVarExpr "Elm.Kernel.Basics" "mul") [ intExpr 4, intExpr 5 ]
                ]
            )
        )


kernelChainedArith : (Src.Module -> Expectation) -> (() -> Expectation)
kernelChainedArith expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.Basics" "add")
                [ callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ intExpr 1, intExpr 2 ]
                , callExpr (qualVarExpr "Elm.Kernel.Basics" "sub") [ intExpr 10, intExpr 5 ]
                ]
            )
        )
