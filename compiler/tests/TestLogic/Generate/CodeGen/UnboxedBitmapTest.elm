module TestLogic.Generate.CodeGen.UnboxedBitmapTest exposing (suite)

{-| Test suite for CGEN\_026, CGEN\_027, CGEN\_003, and CGEN\_049: Unboxed Bitmap Consistency invariants.

CGEN\_026: For container construct ops, bit N of `unboxed_bitmap` must be set
iff operand N is a primitive type.

CGEN\_027: For `eco.construct.list`, `head_unboxed` must be true iff head
operand is primitive.

CGEN\_003: For `eco.papCreate`, bit N of `unboxed_bitmap` must be set iff
captured operand N is a primitive type.

CGEN\_049: For `eco.papExtend`, bit N of `newargs_unboxed_bitmap` must be set
iff new argument operand N is a primitive type.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.UnboxedBitmap exposing (expectUnboxedBitmap)


suite : Test
suite =
    Test.describe "CGEN_026/027/003/049: Unboxed Bitmap Consistency"
        [ StandardTestSuites.expectSuite expectUnboxedBitmap "passes unboxed bitmap invariant"
        ]
