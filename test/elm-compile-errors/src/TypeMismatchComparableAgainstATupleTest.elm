module TypeMismatchComparableAgainstATupleTest exposing (..)

{-| A list whose two tuple entries disagree, one holding a value used with `<`, the other a tuple of numbers in that position, is rejected with a TYPE MISMATCH.

In `[ ( 1, a ), ( "s", ( 1, 2 ) ) ]`, where `a` is compared with `<`, the entries' first
components are a number and a `String`, which cannot agree. Their second components, `a` and
`( 1, 2 )`, can: a tuple of numbers is comparable.

-}

-- COMPILE-ERROR: TYPE MISMATCH, comparable against a tuple
-- CHECK: -- TYPE MISMATCH -

f a = if a < a then [ ( 1, a ), ( "s", ( 1, 2 ) ) ] else []
