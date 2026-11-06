module TypeMismatchUnitsOnBothSidesTest exposing (..)

{-| A list of pairs whose second components differ, `( (), 1 )` and `( (), "a" )`, is rejected
with a TYPE MISMATCH error.

The first components are `()` in both elements, so they agree; the clash is between the
number `1` and the `String` `"a"`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, units on both sides
-- CHECK: -- TYPE MISMATCH -

x = [ ( (), 1 ), ( (), "a" ) ]
