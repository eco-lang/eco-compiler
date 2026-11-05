module TypeMismatchLambdaCallAsAnArgumentTest exposing (..)

{-| TYPE MISMATCH: lambda call as an argument.

From `SourceIR.TypeCheckFailsCases` (`categoryCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, lambda call as an argument
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Only Int and Float values work as numbers.

x = not ((\a -> a + 1) 1)
