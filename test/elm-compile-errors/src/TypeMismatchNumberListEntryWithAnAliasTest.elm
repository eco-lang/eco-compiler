module TypeMismatchNumberListEntryWithAnAliasTest exposing (..)

{-| TYPE MISMATCH: number list entry with an alias.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, number list entry with an alias
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Everything in a list must be the same type of value. T

type alias N = { y : Int }

n : N
n = { y = 1 }

x = [ 1, n ]
