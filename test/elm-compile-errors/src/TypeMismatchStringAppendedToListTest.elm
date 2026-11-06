module TypeMismatchStringAppendedToListTest exposing (..)

{-| Appending a `String` to a list with `++` is rejected with a TYPE MISMATCH.

`[ 1 ] ++ "a"` gives `++` a list on the left and a string on the right; both operands must have the same type.

-}

-- COMPILE-ERROR: TYPE MISMATCH, string appended to list
-- CHECK: -- TYPE MISMATCH -

x = [ 1 ] ++ "a"
