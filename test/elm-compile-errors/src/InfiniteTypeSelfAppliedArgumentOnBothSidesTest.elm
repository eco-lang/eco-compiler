module InfiniteTypeSelfAppliedArgumentOnBothSidesTest exposing (..)

{-| A function argument applied to itself is rejected with an INFINITE TYPE error.

In `k x`, the let binding `y = x x` applies `x` to itself, so the type of `x` would have to
be a function taking its own type. `y` is never used, and the body returns
`[ ( x, 1 ), ( x, "a" ) ]`.

-}

-- COMPILE-ERROR: INFINITE TYPE, self-applied argument on both sides
-- CHECK: -- INFINITE TYPE -

k x =
    let
        y = x x
    in
    [ ( x, 1 ), ( x, "a" ) ]
