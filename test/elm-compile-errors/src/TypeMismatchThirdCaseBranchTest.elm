module TypeMismatchThirdCaseBranchTest exposing (..)

{-| TYPE MISMATCH: third case branch.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, third case branch
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: All branches in a `case` must produce the same type of

x =
    case 1 of
        1 ->
            "a"

        2 ->
            "b"

        _ ->
            2
