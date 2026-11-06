module TypeMismatchNumberPipedIntoNotTest exposing (..)

{-| Piping a number into `not` (`1 |> not`) is rejected with a TYPE MISMATCH error, because `not` takes a `Bool`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, number piped into not
-- CHECK: -- TYPE MISMATCH -

x = 1 |> not
