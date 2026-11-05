module TypeMismatchThirdCaseBranchTest exposing (..)

{-| TYPE MISMATCH: third case branch.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

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
