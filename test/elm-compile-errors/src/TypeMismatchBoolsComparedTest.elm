module TypeMismatchBoolsComparedTest exposing (..)

{-| TYPE MISMATCH: Bools compared.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Bools compared
-- CHECK: -- TYPE MISMATCH -

x = True < False
