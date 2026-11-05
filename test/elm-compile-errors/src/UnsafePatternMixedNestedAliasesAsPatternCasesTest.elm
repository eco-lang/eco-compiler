module UnsafePatternMixedNestedAliasesAsPatternCasesTest exposing (..)

{-| UNSAFE PATTERN: Mixed nested aliases (AsPatternCases).

From `SourceIR.PatternFailsCases` (`testValue`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: UNSAFE PATTERN, Mixed nested aliases (AsPatternCases)
-- CHECK: -- UNSAFE PATTERN -
-- CHECK: []

mixed (( { x }, (h :: _) as list ) as all) =
    all


testValue =
    mixed ( { x = 1 }, [ 1, 2 ] )
