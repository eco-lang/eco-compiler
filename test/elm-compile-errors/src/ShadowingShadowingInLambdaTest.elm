module ShadowingShadowingInLambdaTest exposing (..)

{-| A lambda argument with the same name as an argument of the enclosing function is rejected with a SHADOWING error.

In `test y = \y -> y`, the lambda's `y` shadows the function's `y`.

-}

-- COMPILE-ERROR: SHADOWING, shadowing in lambda
-- CHECK: -- SHADOWING -

test y =
    \y ->
        y
