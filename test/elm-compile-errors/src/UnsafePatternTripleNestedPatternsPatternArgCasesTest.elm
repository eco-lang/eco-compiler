module UnsafePatternTripleNestedPatternsPatternArgCasesTest exposing (..)

{-| UNSAFE PATTERN: Triple nested patterns (PatternArgCases).

From `SourceIR.PatternFailsCases` (`testValue`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: UNSAFE PATTERN, Triple nested patterns (PatternArgCases)
-- CHECK: -- UNSAFE PATTERN -

complex ( ( a, b ), { x, y }, h :: t ) =
    a


testValue =
    complex ( ( 1, "hello" ), { x = 3.14, y = 2 }, [ 3, 4 ] )
