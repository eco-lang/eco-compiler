module TestLogic.Generate.CodeGen.ProjectionLayoutBitmapTest exposing (suite)

{-| Test suite for CGEN\_005: Heap Projection Respects Layout Bitmap.

eco.project.custom result types must match layout bitmap unboxing decisions.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.ProjectionLayoutBitmap exposing (expectProjectionLayoutBitmap)


suite : Test
suite =
    Test.describe "CGEN_005: Projection Layout Bitmap"
        [ StandardTestSuites.expectSuite expectProjectionLayoutBitmap "passes projection layout bitmap invariant"
        ]
