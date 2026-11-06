module TypeMismatchFloatRightOfTimesWithIntTest exposing (..)

{-| The compiler rejects `n * f`, multiplying an `Int` by a `Float`, with a TYPE MISMATCH error, because Elm has no implicit conversion between the two.
-}

-- COMPILE-ERROR: TYPE MISMATCH, Float right of * with Int
-- CHECK: -- TYPE MISMATCH -

f : Float
f = 1.5

n : Int
n = 1

x = n * f
