module SourceIR.KernelHigherOrderCases exposing (expectSuite)

{-| Kernel higher-order tests — kernel functions as arguments, composed with
other kernels.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder exposing (binopsExpr, callExpr, intExpr, lambdaExpr, listExpr, makeKernelModule, pVar, qualVarExpr, strExpr, tupleExpr, varExpr)
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Kernel higher-order " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "List.map with Basics.negate", run = mapWithNegate expectFn }
    , { label = "List.foldl for sum", run = foldlSum expectFn }
    , { label = "List.map on tuples with Tuple.first", run = mapOnTuples expectFn }
    , { label = "Nested List.map", run = nestedMap expectFn }
    , { label = "List.foldl with kernel add", run = foldlWithKernelAdd expectFn }
    ]


mapWithNegate : (Src.Module -> Expectation) -> (() -> Expectation)
mapWithNegate expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Elm.Kernel.List" "map")
            [ qualVarExpr "Elm.Kernel.Basics" "negate"
            , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
            ]))


foldlSum : (Src.Module -> Expectation) -> (() -> Expectation)
foldlSum expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Elm.Kernel.List" "foldl")
            [ lambdaExpr [ pVar "x", pVar "acc" ] (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "acc"))
            , intExpr 0
            , callExpr (qualVarExpr "Elm.Kernel.List" "range") [ intExpr 1, intExpr 10 ]
            ]))


mapOnTuples : (Src.Module -> Expectation) -> (() -> Expectation)
mapOnTuples expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Elm.Kernel.List" "map")
            [ qualVarExpr "Elm.Kernel.Tuple" "first"
            , listExpr [ tupleExpr (intExpr 1) (strExpr "a"), tupleExpr (intExpr 2) (strExpr "b") ]
            ]))


nestedMap : (Src.Module -> Expectation) -> (() -> Expectation)
nestedMap expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Elm.Kernel.List" "map")
            [ lambdaExpr [ pVar "xs" ]
                (callExpr (qualVarExpr "Elm.Kernel.List" "map")
                    [ lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))
                    , varExpr "xs"
                    ])
            , listExpr [ listExpr [ intExpr 1, intExpr 2 ], listExpr [ intExpr 3, intExpr 4 ] ]
            ]))


foldlWithKernelAdd : (Src.Module -> Expectation) -> (() -> Expectation)
foldlWithKernelAdd expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Elm.Kernel.List" "foldl")
            [ qualVarExpr "Elm.Kernel.Basics" "add"
            , intExpr 0
            , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
            ]))
