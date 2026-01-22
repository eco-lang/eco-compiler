module Compiler.Generate.CodeGen.UnboxedBitmapTest exposing (suite)

{-| Test suite for CGEN_026 and CGEN_027: Unboxed Bitmap Consistency invariants.

CGEN_026: For container construct ops, bit N of `unboxed_bitmap` must be set
iff operand N is a primitive type.

CGEN_027: For `eco.construct.list`, `head_unboxed` must be true iff head
operand is primitive.

-}

import Compiler.Generate.CodeGen.UnboxedBitmap exposing (expectUnboxedBitmap)
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_026/027: Unboxed Bitmap Consistency"
        [ StandardTestSuites.expectSuite expectUnboxedBitmap "passes unboxed bitmap invariant"
        ]
