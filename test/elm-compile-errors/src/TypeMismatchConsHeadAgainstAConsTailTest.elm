module TypeMismatchConsHeadAgainstAConsTailTest exposing (..)

{-| TYPE MISMATCH: cons head against a cons tail.

From `SourceIR.TypeCheckFailsCases` (`patternMismatchCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, cons head against a cons tail
-- CHECK: -- TYPE MISMATCH -

x =
    case [ 1 ] of
        1 :: "s" :: rest ->
            1

        _ ->
            2
