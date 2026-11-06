module MissingPatternsAMissingTupleShapeTest exposing (..)

{-| A `case` on a pair of `Bool`s with no branch for `( False, False )` is rejected with a MISSING PATTERNS error.

`either` matches `( True, _ )` and `( False, True )`; the remaining combination is
left uncovered.

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
