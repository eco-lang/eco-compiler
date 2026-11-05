module TypeMismatchTwoArgumentLambdaWhereOneTest exposing (..)

{-| TYPE MISMATCH: two-argument lambda where one.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, two-argument lambda where one
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: It looks like it takes too many arguments. I see 1 ext

f : Int -> Int
f = \a b -> a
