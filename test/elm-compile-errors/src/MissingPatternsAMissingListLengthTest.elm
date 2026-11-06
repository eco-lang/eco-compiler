module MissingPatternsAMissingListLengthTest exposing (..)

{-| A `case` on a list that covers only the empty and one-element lists is rejected with a MISSING PATTERNS error.

`firstOrZero` matches `[]` and `[ x ]` but has no branch for lists of two or more
elements, so the match is not exhaustive.

-}

-- COMPILE-ERROR: MISSING PATTERNS, a missing list length
-- CHECK: -- MISSING PATTERNS -

firstOrZero xs =
    case xs of
        [] ->
            0

        [ x ] ->
            x


testValue =
    firstOrZero [ 1 ]
