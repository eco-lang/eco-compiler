module TypeMismatchStringAppendedToListTest exposing (..)

{-| TYPE MISMATCH: string appended to list.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, string appended to list
-- CHECK: -- TYPE MISMATCH -
-- CHECK: The (++) operator needs the same type of value on both sides

x = [ 1 ] ++ "a"
