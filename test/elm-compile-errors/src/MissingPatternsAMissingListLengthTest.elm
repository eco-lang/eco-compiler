module MissingPatternsAMissingListLengthTest exposing (..)

{-| MISSING PATTERNS: a missing list length.

From `SourceIR.PatternFailsCases` (`testValue`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: MISSING PATTERNS, a missing list length
-- CHECK: -- MISSING PATTERNS -
-- CHECK: _ :: _ :: _

firstOrZero xs =
    case xs of
        [] ->
            0

        [ x ] ->
            x


testValue =
    firstOrZero [ 1 ]
