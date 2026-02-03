module TestLogic.Generate.CodeGen.CtorLayoutConsistencyTest exposing (suite)

{-| Test suite for CGEN\_014: MLIR Uses Only MonoGraph ctorLayouts.

eco.construct.custom attributes must match computed CtorLayout from MonoGraph.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CtorLayoutConsistency exposing (expectCtorLayoutConsistency)


suite : Test
suite =
    Test.describe "CGEN_014: Ctor Layout Consistency"
        [ StandardTestSuites.expectSuite expectCtorLayoutConsistency "passes ctor layout consistency invariant"
        ]
