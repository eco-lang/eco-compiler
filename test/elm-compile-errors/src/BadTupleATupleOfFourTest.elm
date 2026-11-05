module BadTupleATupleOfFourTest exposing (..)

{-| BAD TUPLE: a tuple of four.

From `SourceIR.CanonicalizeFailsCases` (`testValue`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: BAD TUPLE, a tuple of four
-- CHECK: -- BAD TUPLE -
-- CHECK: two or three items

testValue =
    ( 1, 2, 3, 4 )
