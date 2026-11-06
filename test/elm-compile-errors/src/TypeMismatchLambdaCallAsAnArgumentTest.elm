module TypeMismatchLambdaCallAsAnArgumentTest exposing (..)

{-| Passing the result of a lambda call to `not` is rejected with a TYPE MISMATCH.

`(\a -> a + 1) 1` produces a number, while `not` expects a `Bool`. The argument
is a call of a lambda rather than a named function.

-}

-- COMPILE-ERROR: TYPE MISMATCH, lambda call as an argument
-- CHECK: -- TYPE MISMATCH -

x = not ((\a -> a + 1) 1)
