module TypeMismatchIfConditionIntTest exposing (..)

{-| The compiler rejects an `if` whose condition is the number `1` rather than a `Bool`, with a TYPE MISMATCH error.
-}

-- COMPILE-ERROR: TYPE MISMATCH, if condition int
-- CHECK: -- TYPE MISMATCH -

x = if 1 then 2 else 3
