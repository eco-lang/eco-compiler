module TestLogic.Generate.CodeGen.KernelDeclInstanceConsistencyTest exposing (suite)

{-| Test suite for CGEN\_038: Kernel calls use types matching the func.func declaration.

Every Elm\_Kernel\_\* symbol referenced by an eco.call, eco.papCreate, or
eco.papExtend must agree with the symbol's func.func is\_kernel=true
declaration on operand and result MLIR types.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.KernelDeclInstanceConsistency exposing (expectKernelDeclInstanceConsistency)


suite : Test
suite =
    Test.describe "CGEN_038: Kernel decl/instance consistency"
        [ StandardTestSuites.expectSuite expectKernelDeclInstanceConsistency "passes kernel decl/instance consistency invariant"
        ]
