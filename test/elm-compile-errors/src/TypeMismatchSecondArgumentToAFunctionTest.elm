module TypeMismatchSecondArgumentToAFunctionTest exposing (..)

{-| TYPE MISMATCH: second argument to a function.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, second argument to a function
-- CHECK: -- TYPE MISMATCH -

f : Int -> String -> Int
f a b = a

x = f 1 2
