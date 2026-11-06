module TypeMismatchListMultipliedTest exposing (..)

{-| Multiplying a list with `*` is rejected with a TYPE MISMATCH.

`*` needs `number` operands (`Int` or `Float`), and `[ 1 ] * 2` puts a list on the
left.

-}

-- COMPILE-ERROR: TYPE MISMATCH, list multiplied
-- CHECK: -- TYPE MISMATCH -

x = [ 1 ] * 2
