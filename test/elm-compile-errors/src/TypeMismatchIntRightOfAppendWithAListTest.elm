module TypeMismatchIntRightOfAppendWithAListTest exposing (..)

{-| Appending an `Int` to a list with `++` is rejected with a TYPE MISMATCH.

`[ 1 ] ++ n` puts a list on the left of `++` and `n : Int` on the right. `++` needs
both operands to be the same appendable type, and an `Int` is neither a list nor a
`String`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Int right of ++ with a list
-- CHECK: -- TYPE MISMATCH -

n : Int
n = 1

x = [ 1 ] ++ n
