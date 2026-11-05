module NamingErrorAnUnknownVariableTest exposing (..)

{-| NAMING ERROR: an unknown variable.

From `SourceIR.CanonicalizeFailsCases` (`testValue`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: NAMING ERROR, an unknown variable
-- CHECK: -- NAMING ERROR -
-- CHECK: `undefinedName`

testValue =
    undefinedName + 1
