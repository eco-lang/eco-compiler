module TestLogic.Generate.CodeGen.KernelDeclCompletenessTest exposing (suite)

{-| Test suite for CGEN\_057: Kernel Declaration Completeness invariant.

Every kernel function symbol (Elm\_Kernel\_\*) that appears in a papCreate,
papExtend, or eco.call operation must have a corresponding func.func
declaration with is\_kernel=true.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.KernelDeclCompleteness exposing (expectKernelDeclCompleteness)


suite : Test
suite =
    Test.describe "CGEN_057: Kernel Declaration Completeness"
        [ StandardTestSuites.expectSuite expectKernelDeclCompleteness "passes kernel declaration completeness invariant"
        ]
