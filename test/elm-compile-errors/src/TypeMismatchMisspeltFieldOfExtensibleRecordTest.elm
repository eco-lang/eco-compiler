module TypeMismatchMisspeltFieldOfExtensibleRecordTest exposing (main)

{-| TYPE MISMATCH: misspelt field of extensible record.

From `Compiler.Reporting.Render.TypeLayoutReportTest` (`misspeltFieldExtensible`), an elm-test program the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH
-- CHECK: -- TYPE MISMATCH -


g : { a | alpha : Int, beta : Int } -> Int
g r =
    r.alpah


main =
    g { alpha = 1, beta = 2 }
