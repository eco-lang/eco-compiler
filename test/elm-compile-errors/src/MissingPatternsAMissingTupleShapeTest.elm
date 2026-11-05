module MissingPatternsAMissingTupleShapeTest exposing (..)

{-| MISSING PATTERNS: a missing tuple shape.

From `SourceIR.PatternFailsCases` (`testValue`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: MISSING PATTERNS, a missing tuple shape
-- CHECK: -- MISSING PATTERNS -

either pair =
    case pair of
        ( True, _ ) ->
            1

        ( False, True ) ->
            2


testValue =
    either ( True, False )
