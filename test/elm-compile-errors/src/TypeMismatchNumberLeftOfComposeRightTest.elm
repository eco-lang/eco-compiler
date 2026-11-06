module TypeMismatchNumberLeftOfComposeRightTest exposing (..)

{-| A number as the left operand of `>>` (`1 >> not`) is rejected with a TYPE MISMATCH error, because `>>` composes two functions.

-}

-- COMPILE-ERROR: TYPE MISMATCH, number left of >>
-- CHECK: -- TYPE MISMATCH -

x = 1 >> not
