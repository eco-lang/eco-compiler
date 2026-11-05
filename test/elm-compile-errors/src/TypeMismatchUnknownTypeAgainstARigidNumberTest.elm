module TypeMismatchUnknownTypeAgainstARigidNumberTest exposing (..)

{-| TYPE MISMATCH: unknown type against a rigid number.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, unknown type against a rigid number
-- CHECK: -- TYPE MISMATCH -
-- CHECK: ( Maybe number, ? )

f : number -> ( Bool, number )
f x =
    case [ 1, "a" ] of
        h :: _ ->
            ( Just 1, h )

        [] ->
            ( True, x )
