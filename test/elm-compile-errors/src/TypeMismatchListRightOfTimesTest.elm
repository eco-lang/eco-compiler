module TypeMismatchListRightOfTimesTest exposing (..)

{-| Multiplying a number by a list with `*` is rejected with a TYPE MISMATCH.

`*` needs `number` operands (`Int` or `Float`), and `2 * [ 1 ]` puts a list on
the right.

-}

-- COMPILE-ERROR: TYPE MISMATCH, list right of *
-- CHECK: -- TYPE MISMATCH -

x = 2 * [ 1 ]
