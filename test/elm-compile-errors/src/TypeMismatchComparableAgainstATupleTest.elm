module TypeMismatchComparableAgainstATupleTest exposing (..)

{-| TYPE MISMATCH: comparable against a tuple.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, comparable against a tuple
-- CHECK: -- TYPE MISMATCH -

f a = if a < a then [ ( 1, a ), ( "s", ( 1, 2 ) ) ] else []
