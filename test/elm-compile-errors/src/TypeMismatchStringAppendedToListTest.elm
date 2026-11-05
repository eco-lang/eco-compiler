module TypeMismatchStringAppendedToListTest exposing (..)

{-| TYPE MISMATCH: string appended to list.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, string appended to list
-- CHECK: -- TYPE MISMATCH -

x = [ 1 ] ++ "a"
