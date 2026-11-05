module TypeMismatchStringLeftOfPlusTest exposing (..)

{-| TYPE MISMATCH: string left of +.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, string left of +
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Switch to the (++) operator to append strings!

x = "a" + 1
