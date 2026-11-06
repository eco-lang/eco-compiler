module TypeMismatchFloatRightOfIntDivideTest exposing (..)

{-| The compiler rejects the `Float` literal `1.5` on the right of the integer division operator `//`, with a TYPE MISMATCH error.
-}

-- COMPILE-ERROR: TYPE MISMATCH, Float right of //
-- CHECK: -- TYPE MISMATCH -

x = 2 // 1.5
