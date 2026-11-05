module ShadowingShadowingInLambdaTest exposing (..)

{-| SHADOWING: shadowing in lambda.

From `SourceIR.CanonicalizeFailsCases` (`shadowingCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: SHADOWING, shadowing in lambda
-- CHECK: -- SHADOWING -
-- CHECK: The name `y` is first defined here

test y =
    \y ->
        y
