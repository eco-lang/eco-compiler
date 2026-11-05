module TypeMismatchTwoFlexibleRecordsTest exposing (..)

{-| TYPE MISMATCH: two flexible records.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, two flexible records
-- CHECK: -- TYPE MISMATCH -

h a = a.name ++ "s"

k c =
    let
        z = c.name + 1
    in
    h c
