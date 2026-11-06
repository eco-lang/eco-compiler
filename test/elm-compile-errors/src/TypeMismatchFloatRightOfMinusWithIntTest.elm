module TypeMismatchFloatRightOfMinusWithIntTest exposing (..)

{-| The compiler rejects `n - f`, subtracting a `Float` from an `Int`, with a TYPE MISMATCH error, because Elm has no implicit conversion between the two.
-}

-- COMPILE-ERROR: TYPE MISMATCH, Float right of - with Int
-- CHECK: -- TYPE MISMATCH -

f : Float
f = 1.5

n : Int
n = 1

x = n - f
