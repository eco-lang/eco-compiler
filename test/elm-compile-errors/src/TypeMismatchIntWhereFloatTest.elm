module TypeMismatchIntWhereFloatTest exposing (..)

{-| Returning an `Int` from a definition annotated `Float` is rejected with a TYPE MISMATCH.

`x : Float` is defined as `n`, which is annotated `Int`. Elm has no implicit
conversion from `Int` to `Float`; `toFloat` must be called explicitly.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Int where Float
-- CHECK: -- TYPE MISMATCH -

n : Int
n = 1

x : Float
x = n
