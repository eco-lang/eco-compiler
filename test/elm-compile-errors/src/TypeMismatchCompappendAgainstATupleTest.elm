module TypeMismatchCompappendAgainstATupleTest exposing (..)

{-| A list whose two tuple entries disagree, one holding a value used with both `++` and `<`, the other a tuple of numbers in that position, is rejected with a TYPE MISMATCH.

In `[ ( 1, a ), ( "s", ( 1, 2 ) ) ]`, where `a` is appended and compared, the entries differ in
both components: a number against a `String`, and `a` against `( 1, 2 )`, which is a tuple and
cannot be appended.

-}

-- COMPILE-ERROR: TYPE MISMATCH, compappend against a tuple
-- CHECK: -- TYPE MISMATCH -

f a = [ ( 1, if a ++ a < a then a else a ), ( "s", ( 1, 2 ) ) ]
