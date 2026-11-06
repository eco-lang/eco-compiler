module TypeMismatchTwoArgumentLambdaWhereOneTest exposing (..)

{-| A two-argument lambda annotated as `Int -> Int` is rejected with a TYPE MISMATCH.

`f = \a b -> a` returns a function after its first argument, but the annotation promises an `Int`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, two-argument lambda where one
-- CHECK: -- TYPE MISMATCH -

f : Int -> Int
f = \a b -> a
