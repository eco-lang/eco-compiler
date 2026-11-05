module TypeMismatchFieldTypoTest exposing (..)

{-| TYPE MISMATCH: field typo.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, field typo
-- CHECK: -- TYPE MISMATCH -

r = { name = "a" }

x = r.nmae
