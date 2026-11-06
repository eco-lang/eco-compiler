module TypeMismatchFloatLeftOfIntDivideTest exposing (..)

{-| The compiler rejects the `Float` literal `1.5` on the left of the integer division operator `//`, with a TYPE MISMATCH error.
-}

-- COMPILE-ERROR: TYPE MISMATCH, Float left of //
-- CHECK: -- TYPE MISMATCH -

x = 1.5 // 2
