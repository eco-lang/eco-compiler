module TypeMismatchFunctionLeftOfGreaterThanTest exposing (..)

{-| The compiler rejects `not > not`, comparing two functions with `>`, with a TYPE MISMATCH error, because functions are not `comparable`.
-}

-- COMPILE-ERROR: TYPE MISMATCH, function left of >
-- CHECK: -- TYPE MISMATCH -

x = not > not
