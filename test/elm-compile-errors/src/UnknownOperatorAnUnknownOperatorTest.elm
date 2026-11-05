module UnknownOperatorAnUnknownOperatorTest exposing (..)

{-| UNKNOWN OPERATOR: an unknown operator.

From `SourceIR.CanonicalizeFailsCases` (`testValue`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: UNKNOWN OPERATOR, an unknown operator
-- CHECK: -- UNKNOWN OPERATOR -

testValue =
    1 <=> 2
