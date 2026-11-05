module TypeMismatchCompappendListEntryWithABoolTest exposing (..)

{-| TYPE MISMATCH: compappend list entry with a Bool.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, compappend list entry with a Bool
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Everything in a list must be the same type of value. T

f a = [ (if a ++ a < a then a else a), True ]
