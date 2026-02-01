module TestLogic.Generate.CodeGen.ProjectionContainerTypeTest exposing (suite)

{-| Test suite for CGEN_0E1: Projection Container Type invariant.

All projection operations (eco.project.record, eco.project.custom, etc.)
must have !eco.value as their container operand type. This prevents
segfaults from treating primitives as heap pointers.

The dangerous pattern is: project -> eco.unbox -> project
where eco.unbox produces a primitive that is incorrectly used as a container.

-}

import TestLogic.Generate.CodeGen.ProjectionContainerType exposing (expectProjectionContainerType)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_0E1: Projection Container Types"
        [ StandardTestSuites.expectSuite expectProjectionContainerType "passes projection container type invariant"
        ]
