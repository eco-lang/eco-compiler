module TypeMismatchListRightOfAppendWithAStringTest exposing (..)

{-| Appending a list to a `String` with `++` is rejected with a TYPE MISMATCH.

`"a" ++ [ 1 ]` puts a `String` on the left and a list on the right; `++` needs
both operands to be the same appendable type.

-}

-- COMPILE-ERROR: TYPE MISMATCH, list right of ++ with a string
-- CHECK: -- TYPE MISMATCH -

x = "a" ++ [ 1 ]
