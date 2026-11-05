module TypeMismatchCaseAsAnArgumentTest exposing (..)

{-| TYPE MISMATCH: case as an argument.

From `SourceIR.TypeCheckFailsCases` (`categoryCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, case as an argument
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Only Int and Float values work as numbers.

x =
    not
        (case 1 of
            _ ->
                2
        )
