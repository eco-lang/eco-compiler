module CyclicValueALetValueDefinedByItselfTest exposing (..)

{-| A let-bound value defined in terms of itself is rejected with a CYCLIC VALUE error.

Inside `testValue`, the let binding `y` is defined as `y + 1`. It takes no arguments, so
evaluating it would never finish.

-}

-- COMPILE-ERROR: CYCLIC VALUE, a let value defined by itself
-- CHECK: -- CYCLIC VALUE -

testValue =
    let
        y =
            y + 1
    in
    y
