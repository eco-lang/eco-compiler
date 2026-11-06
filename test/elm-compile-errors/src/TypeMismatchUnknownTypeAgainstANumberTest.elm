module TypeMismatchUnknownTypeAgainstANumberTest exposing (..)

{-| A function whose case branches return `( Just 1, h )` and `( True, x + 1 )` is rejected
with a TYPE MISMATCH error.

The scrutinee `[ 1, "a" ]` already mixes a number with a `String`, so the type of `h`,
taken from it, is unknown when it meets the number `x + 1`. The branches' first components,
a `Maybe` and a `Bool`, also disagree. The test checks only that a TYPE MISMATCH is
reported.

-}

-- COMPILE-ERROR: TYPE MISMATCH, unknown type against a number
-- CHECK: -- TYPE MISMATCH -

f x =
    case [ 1, "a" ] of
        h :: _ ->
            ( Just 1, h )

        [] ->
            ( True, x + 1 )
