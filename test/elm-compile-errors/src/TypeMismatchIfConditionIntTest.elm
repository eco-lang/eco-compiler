module TypeMismatchIfConditionIntTest exposing (..)

{-| TYPE MISMATCH: if condition int.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, if condition int
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Only Int and Float values work as numbers.

x = if 1 then 2 else 3
