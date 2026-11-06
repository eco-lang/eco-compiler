module TypeMismatchThirdCaseBranchTest exposing (..)

{-| A `case` whose third branch returns a number while the first two return `String`s is rejected with a TYPE MISMATCH.

Every branch of a `case` must produce the same type; the branches return `"a"`, `"b"` and `2`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, third case branch
-- CHECK: -- TYPE MISMATCH -

x =
    case 1 of
        1 ->
            "a"

        2 ->
            "b"

        _ ->
            2
