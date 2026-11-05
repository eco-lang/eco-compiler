module TypeMismatchAppendableAgainstATupleTest exposing (..)

{-| TYPE MISMATCH: appendable against a tuple.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, appendable against a tuple
-- CHECK: -- TYPE MISMATCH -
-- CHECK: appendable

f a = [ ( 1, a ++ a ), ( "s", ( 1, 2 ) ) ]
