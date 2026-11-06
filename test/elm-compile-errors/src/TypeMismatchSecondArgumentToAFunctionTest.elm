module TypeMismatchSecondArgumentToAFunctionTest exposing (..)

{-| Passing a number as the second argument of a function that expects a `String` there is rejected with a TYPE MISMATCH.

`f : Int -> String -> Int` is called as `f 1 2`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, second argument to a function
-- CHECK: -- TYPE MISMATCH -

f : Int -> String -> Int
f a b = a

x = f 1 2
