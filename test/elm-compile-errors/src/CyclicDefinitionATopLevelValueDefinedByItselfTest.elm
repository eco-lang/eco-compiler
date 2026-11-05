module CyclicDefinitionATopLevelValueDefinedByItselfTest exposing (..)

{-| CYCLIC DEFINITION: a top-level value defined by itself.

From `SourceIR.CanonicalizeFailsCases` (`otherCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: CYCLIC DEFINITION, a top-level value defined by itself
-- CHECK: -- CYCLIC DEFINITION -

loop =
    loop + 1


testValue =
    loop
