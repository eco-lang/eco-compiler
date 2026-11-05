module ShadowingAnArgumentShadowingATopLevelValueTest exposing (..)

{-| SHADOWING: an argument shadowing a top-level value.

From `SourceIR.CanonicalizeFailsCases` (`testValue`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: SHADOWING, an argument shadowing a top-level value
-- CHECK: -- SHADOWING -

scale =
    2


double scale =
    scale * 2


testValue =
    double 3
