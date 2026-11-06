module TypeMismatchNumberPipedIntoANumberTest exposing (..)

{-| Piping a number into another number (`1 |> 2`) is rejected with a TYPE MISMATCH error, because `|>` applies its right operand as a function.

-}

-- COMPILE-ERROR: TYPE MISMATCH, number piped into a number
-- CHECK: -- TYPE MISMATCH -

x = 1 |> 2
