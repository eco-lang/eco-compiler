module UnsafePatternMixedNestedAliasesAsPatternCasesTest exposing (..)

{-| A function parameter pattern `(( { x }, (h :: _) as list ) as all)` is rejected with an
UNSAFE PATTERN error.

A function's parameter patterns must match every value of their type. The record pattern
and the `as` aliases always match, but the nested cons pattern `h :: _` fails on the empty
list.

-}

-- COMPILE-ERROR: UNSAFE PATTERN, Mixed nested aliases (AsPatternCases)
-- CHECK: -- UNSAFE PATTERN -

mixed (( { x }, (h :: _) as list ) as all) =
    all


testValue =
    mixed ( { x = 1 }, [ 1, 2 ] )
