module TypeMismatchListRightOfPlusTest exposing (..)

{-| Adding a list to a number with `+` is rejected with a TYPE MISMATCH.

`+` needs `number` operands (`Int` or `Float`), and `1 + [ 2 ]` puts a list on
the right.

-}

-- COMPILE-ERROR: TYPE MISMATCH, list right of +
-- CHECK: -- TYPE MISMATCH -

x = 1 + [ 2 ]
