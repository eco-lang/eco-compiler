module TypeMismatchTypeWhereAnAliasTest exposing (..)

{-| TYPE MISMATCH: type where an alias.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, type where an alias
-- CHECK: -- TYPE MISMATCH -

type alias P = Int

x : P
x = "s"
