module TypeMismatchBoolLeftOfAppendTest exposing (..)

{-| TYPE MISMATCH: Bool left of ++.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Bool left of ++
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: I only know how to append strings and lists.

x = True ++ "a"
