module UnknownOperatorAnUnknownOperatorTest exposing (..)

{-| Using an operator that no module defines, `1 <=> 2`, is rejected with an UNKNOWN OPERATOR
error.

-}

-- COMPILE-ERROR: UNKNOWN OPERATOR, an unknown operator
-- CHECK: -- UNKNOWN OPERATOR -

testValue =
    1 <=> 2
