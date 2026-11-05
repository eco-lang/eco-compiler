module TypeMismatchUpdateOfANumberTest exposing (..)

{-| TYPE MISMATCH: update of a number.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, update of a number
-- CHECK: -- TYPE MISMATCH -
-- CHECK: This `n` value is a:

n : Int
n = 1

y = { n | x = 1 }
