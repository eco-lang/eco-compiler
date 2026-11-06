module TypeMismatchOneArgumentFunctionWhereTwoTest exposing (..)

{-| Defining `f : Int -> Int -> Int` as a function of type `Int -> Int` (`f = g`) is rejected with a TYPE MISMATCH error.

`g` returns an `Int` after one argument, where the annotation of `f` requires it to return another function.

-}

-- COMPILE-ERROR: TYPE MISMATCH, one-argument function where two
-- CHECK: -- TYPE MISMATCH -

g : Int -> Int
g a = a

f : Int -> Int -> Int
f = g
