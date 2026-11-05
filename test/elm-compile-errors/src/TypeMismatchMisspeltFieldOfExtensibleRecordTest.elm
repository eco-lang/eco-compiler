module TypeMismatchMisspeltFieldOfExtensibleRecordTest exposing (main)

{-| TYPE MISMATCH: misspelt field of extensible record.

From `Compiler.Reporting.Render.TypeLayoutReportTest` (`misspeltFieldExtensible`), an elm-test program the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH
-- CHECK: -- TYPE MISMATCH -
-- CHECK: This `r` record does not have a `alpah` field:
-- CHECK: This is usually a typo. Here are the `r` fields that are most similar:
-- CHECK: { a


g : { a | alpha : Int, beta : Int } -> Int
g r =
    r.alpah


main =
    g { alpha = 1, beta = 2 }
