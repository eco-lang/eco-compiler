module UnsafePatternTripleNestedPatternsPatternArgCasesTest exposing (..)

{-| A function parameter pattern `( ( a, b ), { x, y }, h :: t )` is rejected with an UNSAFE
PATTERN error.

A function's parameter patterns must match every value of their type. The nested tuple and
the record pattern always match, but the cons pattern `h :: t` in the third position fails
on the empty list.

-}

-- COMPILE-ERROR: UNSAFE PATTERN, Triple nested patterns (PatternArgCases)
-- CHECK: -- UNSAFE PATTERN -

complex ( ( a, b ), { x, y }, h :: t ) =
    a


testValue =
    complex ( ( 1, "hello" ), { x = 3.14, y = 2 }, [ 3, 4 ] )
