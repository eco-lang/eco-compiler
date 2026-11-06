module TypeMismatchConsHeadAgainstAConsTailTest exposing (..)

{-| A list pattern `1 :: "s" :: rest` is rejected with a TYPE MISMATCH, because it asks for a number and a `String` as elements of the same list.

-}

-- COMPILE-ERROR: TYPE MISMATCH, cons head against a cons tail
-- CHECK: -- TYPE MISMATCH -

x =
    case [ 1 ] of
        1 :: "s" :: rest ->
            1

        _ ->
            2
