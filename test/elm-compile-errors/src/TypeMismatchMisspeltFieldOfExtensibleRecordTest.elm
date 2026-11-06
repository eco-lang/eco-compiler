module TypeMismatchMisspeltFieldOfExtensibleRecordTest exposing (main)

{-| A function annotated to take an extensible record with fields `alpha` and `beta` that reads the misspelt field `r.alpah` is rejected with a TYPE MISMATCH error.

The annotation fixes which fields `r` is known to have, so accessing a field not among them cannot type-check, even though the record type is extensible.

-}

-- COMPILE-ERROR: TYPE MISMATCH
-- CHECK: -- TYPE MISMATCH -


g : { a | alpha : Int, beta : Int } -> Int
g r =
    r.alpah


main =
    g { alpha = 1, beta = 2 }
