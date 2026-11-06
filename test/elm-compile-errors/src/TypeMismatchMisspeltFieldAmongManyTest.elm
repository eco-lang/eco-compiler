module TypeMismatchMisspeltFieldAmongManyTest exposing (main)

{-| Accessing a misspelt field of a record with many fields is rejected with a TYPE MISMATCH.

`r1` has the fields `alpha`, `beta`, `gamma`, `delta` and `epsilon`, and `main`
reads `r1.alpah`, which none of them is.

-}

-- COMPILE-ERROR: TYPE MISMATCH
-- CHECK: -- TYPE MISMATCH -


r1 =
    { alpha = 1, beta = 2, gamma = 3, delta = 4, epsilon = 5 }


main =
    r1.alpah
