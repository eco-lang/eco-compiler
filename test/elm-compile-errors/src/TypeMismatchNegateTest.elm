module TypeMismatchNegateTest exposing (..)

{-| Negating a `String` with the prefix minus (`-s`) is rejected with a TYPE MISMATCH error.

Prefix minus is `negate`, which takes a `number`, and a `String` is not one.

-}

-- COMPILE-ERROR: TYPE MISMATCH, negate
-- CHECK: -- TYPE MISMATCH -

s = "s"

x = -s
