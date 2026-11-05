module TypeMismatchTupleAgainstAnAliasTest exposing (..)

{-| TYPE MISMATCH: tuple against an alias.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, tuple against an alias
-- CHECK: -- TYPE MISMATCH -

type alias N = Int

m : N
m = 1

y = [ m, ( 1, 2 ) ]
