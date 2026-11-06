module TypeMismatchAppendableAgainstATupleTest exposing (..)

{-| A list whose tuple elements disagree in both components is rejected with a TYPE MISMATCH.

In `f a = [ ( 1, a ++ a ), ( "s", ( 1, 2 ) ) ]` the first element pairs a number with an
appendable `a ++ a`, and the second pairs a `String` with a tuple of numbers.

-}

-- COMPILE-ERROR: TYPE MISMATCH, appendable against a tuple
-- CHECK: -- TYPE MISMATCH -

f a = [ ( 1, a ++ a ), ( "s", ( 1, 2 ) ) ]
