module TypeMismatchIntRightOfDivideTest exposing (..)

{-| Dividing by an `Int` with `/` is rejected with a TYPE MISMATCH.

`/` is `Float -> Float -> Float`, and Elm never converts an `Int` to a `Float`
implicitly, so `2 / n` with `n : Int` must not compile.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Int right of /
-- CHECK: -- TYPE MISMATCH -

n : Int
n = 1

x = 2 / n
