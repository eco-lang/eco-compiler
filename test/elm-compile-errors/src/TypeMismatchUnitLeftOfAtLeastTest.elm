module TypeMismatchUnitLeftOfAtLeastTest exposing (..)

{-| Comparing two unit values with `>=` is rejected with a TYPE MISMATCH error.

`>=` takes `comparable` arguments, and `()` is not comparable.

-}

-- COMPILE-ERROR: TYPE MISMATCH, unit left of >=
-- CHECK: -- TYPE MISMATCH -

x = () >= ()
