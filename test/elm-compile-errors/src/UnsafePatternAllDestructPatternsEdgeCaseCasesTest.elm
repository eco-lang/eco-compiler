module UnsafePatternAllDestructPatternsEdgeCaseCasesTest exposing (..)

{-| UNSAFE PATTERN: All destruct patterns (EdgeCaseCases).

From `SourceIR.PatternFailsCases` (`testValue`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: UNSAFE PATTERN, All destruct patterns (EdgeCaseCases)
-- CHECK: -- UNSAFE PATTERN -

testValue =
    let
        ( a, b ) =
            ( 1, 2 )

        { x } =
            { x = 3 }

        (h :: t) =
            [ 4, 5 ]

        (v as w) =
            6
    in
    [ a, x, h, v ]
