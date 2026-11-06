module RedundantPatternABranchAfterAWildcardTest exposing (..)

{-| A `case` branch placed after a wildcard branch is rejected with a REDUNDANT PATTERN error.

In `name`, the `_` branch comes first and matches every value, so the following `0`
branch can never be reached.

-}

-- COMPILE-ERROR: REDUNDANT PATTERN, a branch after a wildcard
-- CHECK: -- REDUNDANT PATTERN -

name n =
    case n of
        _ ->
            "any"

        0 ->
            "zero"


testValue =
    name 0
