module TypeMismatchStringLeftOfIntDivideTest exposing (..)

{-| A `String` as the left operand of `//` is rejected with a TYPE MISMATCH.

`"a" // 2`: integer division takes two `Int`s.

-}

-- COMPILE-ERROR: TYPE MISMATCH, String left of //
-- CHECK: -- TYPE MISMATCH -

x = "a" // 2
