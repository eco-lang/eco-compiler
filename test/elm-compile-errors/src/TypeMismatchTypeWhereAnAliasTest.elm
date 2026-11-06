module TypeMismatchTypeWhereAnAliasTest exposing (..)

{-| A value annotated with a type alias of `Int` but defined as a `String` is rejected with a
TYPE MISMATCH error.

`type alias P = Int` makes `P` another name for `Int`, so `x : P` expects an `Int`, and
`"s"` does not fit it.

-}

-- COMPILE-ERROR: TYPE MISMATCH, type where an alias
-- CHECK: -- TYPE MISMATCH -

type alias P = Int

x : P
x = "s"
