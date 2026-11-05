module TypeMismatchCompappendAgainstATupleTest exposing (..)

{-| TYPE MISMATCH: compappend against a tuple.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, compappend against a tuple
-- CHECK: -- TYPE MISMATCH -
-- CHECK: compappend

f a = [ ( 1, if a ++ a < a then a else a ), ( "s", ( 1, 2 ) ) ]
