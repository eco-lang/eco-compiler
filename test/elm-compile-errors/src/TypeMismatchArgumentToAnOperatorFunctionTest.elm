module TypeMismatchArgumentToAnOperatorFunctionTest exposing (..)

{-| A `String` passed to the operator function `(+)` is rejected with a TYPE MISMATCH.

`x = (+) "a" 1` uses `+` in prefix form; its arguments must be numbers, and `"a"` is a `String`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, argument to an operator function
-- CHECK: -- TYPE MISMATCH -

x = (+) "a" 1
