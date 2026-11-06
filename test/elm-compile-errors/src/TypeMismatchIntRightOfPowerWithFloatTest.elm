module TypeMismatchIntRightOfPowerWithFloatTest exposing (..)

{-| Raising a `Float` to an `Int` power with `^` is rejected with a TYPE MISMATCH.

`^` takes two operands of the same `number` type. In `f ^ n` the left side is
`f : Float` and the right side `n : Int`; Elm does not convert between them.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Int right of ^ with Float
-- CHECK: -- TYPE MISMATCH -

f : Float
f = 1.5

n : Int
n = 1

x = f ^ n
