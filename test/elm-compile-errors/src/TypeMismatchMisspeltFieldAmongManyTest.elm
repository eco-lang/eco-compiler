module TypeMismatchMisspeltFieldAmongManyTest exposing (main)

{-| TYPE MISMATCH: misspelt field among many.

From `Compiler.Reporting.Render.TypeLayoutReportTest` (`misspeltFieldMany`), an elm-test program the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH
-- CHECK: -- TYPE MISMATCH -


r1 =
    { alpha = 1, beta = 2, gamma = 3, delta = 4, epsilon = 5 }


main =
    r1.alpah
