module SourceIR.KernelCtorArgCases exposing (expectSuite)

{-| Test cases for constructors called with kernel function arguments.

Targets PostSolve.postSolveCallWithCtorKernelArgs and related type
unification code, plus KernelAbi type conversion for complex types.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( callExpr
        , ctorExpr
        , intExpr
        , listExpr
        , makeKernelModule
        , makeModuleWithTypedDefsUnionsAliases
        , qualVarExpr
        , strExpr
        , tType
        , tVar
        , tupleExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Kernel ctor args " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Tuple with kernel result", run = tupleWithKernel expectFn }
    , { label = "List of kernel results", run = listOfKernelResults expectFn }
    , { label = "Kernel result in let then ctor", run = kernelInLetThenCtor expectFn }
    , { label = "Custom ctor with kernel arg", run = customCtorWithKernel expectFn }
    , { label = "Nested kernel in tuple", run = nestedKernelTuple expectFn }
    , { label = "Kernel identity on tuple", run = kernelIdentityTuple expectFn }
    , { label = "Kernel identity on record-like tuple", run = kernelIdentityRecordTuple expectFn }
    ]


tupleWithKernel : (Src.Module -> Expectation) -> (() -> Expectation)
tupleWithKernel expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (tupleExpr
                (callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ intExpr 1, intExpr 2 ])
                (callExpr (qualVarExpr "Elm.Kernel.Basics" "mul") [ intExpr 3, intExpr 4 ])
            )
        )


listOfKernelResults : (Src.Module -> Expectation) -> (() -> Expectation)
listOfKernelResults expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (listExpr
                [ callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ intExpr 1, intExpr 2 ]
                , callExpr (qualVarExpr "Elm.Kernel.Basics" "sub") [ intExpr 5, intExpr 3 ]
                , callExpr (qualVarExpr "Elm.Kernel.Basics" "mul") [ intExpr 2, intExpr 2 ]
                ]
            )
        )


kernelInLetThenCtor : (Src.Module -> Expectation) -> (() -> Expectation)
kernelInLetThenCtor expectFn _ =
    let
        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ { name = "testValue"
                  , args = []
                  , tipe = tType "Wrapper" [ tType "Int" [] ]
                  , body =
                        callExpr (ctorExpr "Wrap")
                            [ callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ intExpr 10, intExpr 20 ] ]
                  }
                ]
                [ { name = "Wrapper"
                  , args = [ "a" ]
                  , ctors = [ { name = "Wrap", args = [ tVar "a" ] } ]
                  }
                ]
                []
    in
    expectFn modul


customCtorWithKernel : (Src.Module -> Expectation) -> (() -> Expectation)
customCtorWithKernel expectFn _ =
    let
        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ { name = "testValue"
                  , args = []
                  , tipe = tType "Pair" [ tType "Int" [], tType "String" [] ]
                  , body =
                        callExpr (ctorExpr "MkPair")
                            [ callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ intExpr 1, intExpr 2 ]
                            , callExpr (qualVarExpr "Elm.Kernel.String" "fromNumber") [ intExpr 42 ]
                            ]
                  }
                ]
                [ { name = "Pair"
                  , args = [ "a", "b" ]
                  , ctors = [ { name = "MkPair", args = [ tVar "a", tVar "b" ] } ]
                  }
                ]
                []
    in
    expectFn modul


nestedKernelTuple : (Src.Module -> Expectation) -> (() -> Expectation)
nestedKernelTuple expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (tupleExpr
                (tupleExpr (callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ intExpr 1, intExpr 2 ]) (intExpr 3))
                (callExpr (qualVarExpr "Elm.Kernel.Basics" "mul") [ intExpr 4, intExpr 5 ])
            )
        )


kernelIdentityTuple : (Src.Module -> Expectation) -> (() -> Expectation)
kernelIdentityTuple expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.Basics" "identity")
                [ tupleExpr (intExpr 1) (strExpr "hello") ]
            )
        )


kernelIdentityRecordTuple : (Src.Module -> Expectation) -> (() -> Expectation)
kernelIdentityRecordTuple expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.Basics" "identity")
                [ listExpr [ tupleExpr (intExpr 1) (intExpr 2), tupleExpr (intExpr 3) (intExpr 4) ] ]
            )
        )
