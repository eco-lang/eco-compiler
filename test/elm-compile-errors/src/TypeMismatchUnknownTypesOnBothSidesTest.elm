module TypeMismatchUnknownTypesOnBothSidesTest exposing (..)

{-| TYPE MISMATCH: unknown types on both sides.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, unknown types on both sides
-- CHECK: -- TYPE MISMATCH -

x =
    case [ 1, "a" ] of
        h :: _ ->
            [ ( h, 1 ), ( h, "a" ) ]

        [] ->
            []
