module TypeMismatchLambdaArgumentPatternTest exposing (..)

{-| Applying a lambda with a tuple pattern to a number is rejected with a TYPE MISMATCH.

The lambda `\( a, b ) -> a` destructures its argument as a pair, but it is applied
to the number literal `1`, which cannot be a tuple.

-}

-- COMPILE-ERROR: TYPE MISMATCH, lambda argument pattern
-- CHECK: -- TYPE MISMATCH -

x = (\( a, b ) -> a) 1
