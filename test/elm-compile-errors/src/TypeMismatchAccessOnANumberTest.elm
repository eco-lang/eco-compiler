module TypeMismatchAccessOnANumberTest exposing (..)

{-| TYPE MISMATCH: access on a number.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, access on a number
-- CHECK: -- TYPE MISMATCH -

n : Int
n = 1

x = n.foo
