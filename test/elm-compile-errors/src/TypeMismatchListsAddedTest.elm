module TypeMismatchListsAddedTest exposing (..)

{-| Adding two lists with `+` is rejected with a TYPE MISMATCH.

`+` needs `number` operands (`Int` or `Float`); `[ 1 ] + [ 2 ]` gives it two lists.
Lists are joined with `++`, not `+`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, lists added
-- CHECK: -- TYPE MISMATCH -

x = [ 1 ] + [ 2 ]
