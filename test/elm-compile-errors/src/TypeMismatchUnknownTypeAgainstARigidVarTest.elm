module TypeMismatchUnknownTypeAgainstARigidVarTest exposing (..)

{-| TYPE MISMATCH: unknown type against a rigid var.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, unknown type against a rigid var
-- CHECK: -- TYPE MISMATCH -
-- CHECK: ( Maybe number, ? )

f : a -> ( Bool, a )
f x =
    case [ 1, "a" ] of
        h :: _ ->
            ( Just 1, h )

        [] ->
            ( True, x )
