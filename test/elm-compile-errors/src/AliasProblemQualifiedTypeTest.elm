module AliasProblemQualifiedTypeTest exposing (..)

{-| ALIAS PROBLEM: qualified type.

From `SourceIR.CanonicalizeFailsCases` (`aliasCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: ALIAS PROBLEM, qualified type
-- CHECK: -- ALIAS PROBLEM -
-- CHECK: Maybe.Maybe (List A)

type alias A = Maybe.Maybe (List A)
