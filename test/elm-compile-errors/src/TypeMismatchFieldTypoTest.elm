module TypeMismatchFieldTypoTest exposing (..)

{-| TYPE MISMATCH: field typo.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, field typo
-- CHECK: -- TYPE MISMATCH -
-- CHECK: This is usually a typo. Here are the `r` fields that are mos

r = { name = "a" }

x = r.nmae
