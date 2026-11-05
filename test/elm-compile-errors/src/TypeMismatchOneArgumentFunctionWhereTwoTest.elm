module TypeMismatchOneArgumentFunctionWhereTwoTest exposing (..)

{-| TYPE MISMATCH: one-argument function where two.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, one-argument function where two
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: It looks like it takes too few arguments. I was expect

g : Int -> Int
g a = a

f : Int -> Int -> Int
f = g
