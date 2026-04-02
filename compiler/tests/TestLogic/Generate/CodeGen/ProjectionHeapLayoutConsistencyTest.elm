module TestLogic.Generate.CodeGen.ProjectionHeapLayoutConsistencyTest exposing (suite)

{-| Test suite for REP\_BOUNDARY\_003: Projection result types match heap field layout.

Verifies that eco.project.list\_head result types are consistent with the
monomorphized list element type from the MonoGraph.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.ProjectionHeapLayoutConsistency exposing (expectProjectionHeapLayoutConsistency)


suite : Test
suite =
    Test.describe "REP_BOUNDARY_003: Projection heap layout consistency"
        [ StandardTestSuites.expectSuite expectProjectionHeapLayoutConsistency "passes projection heap layout consistency"
        ]
