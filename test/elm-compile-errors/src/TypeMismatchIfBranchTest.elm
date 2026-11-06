module TypeMismatchIfBranchTest exposing (..)

{-| The compiler rejects an `if` whose `then` branch is a number and whose `else` branch is a `String`, with a TYPE MISMATCH error.
-}

-- COMPILE-ERROR: TYPE MISMATCH, if branch
-- CHECK: -- TYPE MISMATCH -

x = if True then 1 else "a"
