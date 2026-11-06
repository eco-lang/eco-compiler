module TypeMismatchIntAgainstNumberAfterAMismatchTest exposing (..)

{-| The compiler rejects a list of pairs whose second entry has a `String` first component where the first entry has a number, with a TYPE MISMATCH error.

The second components, the literal `1` and the `Int` value `n`, agree with each other; only the
first components disagree.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Int against number after a mismatch
-- CHECK: -- TYPE MISMATCH -

n : Int
n = 1

x = [ ( 1, 1 ), ( "a", n ) ]
