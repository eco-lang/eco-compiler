module TypeMismatchFloatRightOfPowerWithIntTest exposing (..)

{-| The compiler rejects `n ^ f`, raising an `Int` to a `Float` power, with a TYPE MISMATCH error, because `^` needs both sides to be the same number type.
-}

-- COMPILE-ERROR: TYPE MISMATCH, Float right of ^ with Int
-- CHECK: -- TYPE MISMATCH -

f : Float
f = 1.5

n : Int
n = 1

x = n ^ f
