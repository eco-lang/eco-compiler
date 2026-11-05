module RedundantPatternABranchAfterAWildcardTest exposing (..)

{-| REDUNDANT PATTERN: a branch after a wildcard.

From `SourceIR.PatternFailsCases` (`redundantCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: REDUNDANT PATTERN, a branch after a wildcard
-- CHECK: -- REDUNDANT PATTERN -
-- CHECK: The 2nd pattern is redundant

name n =
    case n of
        _ ->
            "any"

        0 ->
            "zero"


testValue =
    name 0
