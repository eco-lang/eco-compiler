module TestLogic.Generate.CodeGen.UnboxedBitmapTest exposing (suite)

{-| Test suite for CGEN_026, CGEN_027, CGEN_003, and CGEN_049: Unboxed Bitmap Consistency invariants.

CGEN_026: For container construct ops, bit N of `unboxed_bitmap` must be set
iff operand N is a primitive type.

CGEN_027: For `eco.construct.list`, `head_unboxed` must be true iff head
operand is primitive.

CGEN_003: For `eco.papCreate`, bit N of `unboxed_bitmap` must be set iff
captured operand N is a primitive type.

CGEN_049: For `eco.papExtend`, bit N of `newargs_unboxed_bitmap` must be set
iff new argument operand N is a primitive type.

-}

import TestLogic.Generate.CodeGen.UnboxedBitmap exposing (expectUnboxedBitmap)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_026/027/003/049: Unboxed Bitmap Consistency"
        [ StandardTestSuites.expectSuite expectUnboxedBitmap "passes unboxed bitmap invariant"
        ]
