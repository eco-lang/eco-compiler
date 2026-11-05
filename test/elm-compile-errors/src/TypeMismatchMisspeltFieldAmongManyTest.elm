module TypeMismatchMisspeltFieldAmongManyTest exposing (main)

{-| TYPE MISMATCH: misspelt field among many.

From `Compiler.Reporting.Render.TypeLayoutReportTest` (`misspeltFieldMany`), an elm-test program the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH
-- CHECK: -- TYPE MISMATCH -
-- CHECK: This `r1` record does not have a `alpah` field:
-- CHECK: This is usually a typo. Here are the `r1` fields that are most similar:
-- CHECK: { alpha : number


r1 =
    { alpha = 1, beta = 2, gamma = 3, delta = 4, epsilon = 5 }


main =
    r1.alpah
