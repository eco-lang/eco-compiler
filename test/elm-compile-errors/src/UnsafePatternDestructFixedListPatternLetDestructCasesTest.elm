module UnsafePatternDestructFixedListPatternLetDestructCasesTest exposing (..)

{-| UNSAFE PATTERN: Destruct fixed list pattern (LetDestructCases).

From `SourceIR.PatternFailsCases` (`testValue`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: UNSAFE PATTERN, Destruct fixed list pattern (LetDestructCases)
-- CHECK: -- UNSAFE PATTERN -

testValue =
    let
        [ a, b ] =
            [ 1, 2 ]
    in
    ( a, b )
