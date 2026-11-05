module TypeMismatchUnknownTypeAgainstANumberTest exposing (..)

{-| TYPE MISMATCH: unknown type against a number.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, unknown type against a number
-- CHECK: -- TYPE MISMATCH -

f x =
    case [ 1, "a" ] of
        h :: _ ->
            ( Just 1, h )

        [] ->
            ( True, x + 1 )
