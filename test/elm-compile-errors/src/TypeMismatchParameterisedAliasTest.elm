module TypeMismatchParameterisedAliasTest exposing (..)

{-| TYPE MISMATCH: parameterised alias.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, parameterised alias
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Want to convert an Int into a String? Use the String.f

type alias Box a = { v : a }

b : Box Int
b = { v = 1 }

x : Box String
x = b
