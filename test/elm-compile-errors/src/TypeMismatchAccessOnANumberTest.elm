module TypeMismatchAccessOnANumberTest exposing (..)

{-| Field access on an `Int` is rejected with a TYPE MISMATCH.

`n` is annotated `Int`, and `x = n.foo` reads a field `foo` from it.

-}

-- COMPILE-ERROR: TYPE MISMATCH, access on a number
-- CHECK: -- TYPE MISMATCH -

n : Int
n = 1

x = n.foo
