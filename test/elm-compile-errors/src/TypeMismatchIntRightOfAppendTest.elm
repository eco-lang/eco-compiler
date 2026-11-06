module TypeMismatchIntRightOfAppendTest exposing (..)

{-| The compiler rejects `"a" ++ n`, appending an `Int` to a `String`, with a TYPE MISMATCH error.
-}

-- COMPILE-ERROR: TYPE MISMATCH, Int right of ++
-- CHECK: -- TYPE MISMATCH -

n : Int
n = 1

x = "a" ++ n
