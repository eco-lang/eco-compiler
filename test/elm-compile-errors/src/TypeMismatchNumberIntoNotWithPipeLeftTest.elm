module TypeMismatchNumberIntoNotWithPipeLeftTest exposing (..)

{-| Applying `not` to a number with `<|` (`not <| 1`) is rejected with a TYPE MISMATCH error, because `not` takes a `Bool`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, number into not with <|
-- CHECK: -- TYPE MISMATCH -

x = not <| 1
