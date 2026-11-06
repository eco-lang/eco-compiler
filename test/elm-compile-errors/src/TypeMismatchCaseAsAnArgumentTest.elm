module TypeMismatchCaseAsAnArgumentTest exposing (..)

{-| A `case` expression passed as the argument to `not` is rejected with a TYPE MISMATCH, because its branch yields a number and `not` takes a `Bool`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, case as an argument
-- CHECK: -- TYPE MISMATCH -

x =
    not
        (case 1 of
            _ ->
                2
        )
