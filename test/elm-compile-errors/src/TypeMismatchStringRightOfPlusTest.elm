module TypeMismatchStringRightOfPlusTest exposing (..)

{-| TYPE MISMATCH: string right of +.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, string right of +
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Switch to the (++) operator to append strings!

x = 1 + "a"
