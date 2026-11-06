module TypeMismatchSelfAppliedArgumentAgainstANumberTest exposing (..)

{-| An unannotated function argument that is applied to itself and also used as a numeric function is rejected with a TYPE MISMATCH.

In `k x`, a `let` computes `x x`, and the body puts `x` in a list beside `\v -> v + 1`. Self-application needs `x` to accept a value of its own type, which no `number -> number` function does.

-}

-- COMPILE-ERROR: TYPE MISMATCH, self-applied argument against a number
-- CHECK: -- TYPE MISMATCH -

k x =
    let
        y = x x
    in
    [ x, \v -> v + 1 ]
