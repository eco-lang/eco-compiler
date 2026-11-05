module TypeMismatchTwoComparableVarsTest exposing (..)

{-| TYPE MISMATCH: two comparable vars.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, two comparable vars
-- CHECK: -- TYPE MISMATCH -
-- CHECK: comparable

type A = A

type B = B

f a b = if a < a && b < b then [ ( A, a ), ( B, b ) ] else []
