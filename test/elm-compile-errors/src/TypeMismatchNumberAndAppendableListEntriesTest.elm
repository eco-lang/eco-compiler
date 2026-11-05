module TypeMismatchNumberAndAppendableListEntriesTest exposing (..)

{-| TYPE MISMATCH: number and appendable list entries.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, number and appendable list entries
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Everything in a list must be the same type of value. T

f a b = [ a + 1, b ++ b ]
