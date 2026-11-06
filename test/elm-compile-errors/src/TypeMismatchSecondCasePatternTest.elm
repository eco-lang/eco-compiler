module TypeMismatchSecondCasePatternTest exposing (..)

{-| A `case` on a `String` whose second pattern is a `Char` literal is rejected with a TYPE MISMATCH.

The patterns are `"a"`, `'c'` and `_`; the second does not match the type of the scrutinee `"s"`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, second case pattern
-- CHECK: -- TYPE MISMATCH -

x =
    case "s" of
        "a" ->
            1

        'c' ->
            2

        _ ->
            3
