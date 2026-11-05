module TypeMismatchSelfAppliedArgumentAgainstARigidVarTest exposing (..)

{-| TYPE MISMATCH: self-applied argument against a rigid var.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, self-applied argument against a rigid var
-- CHECK: -- TYPE MISMATCH -
-- CHECK: ∞

h : a -> Int
h w =
    let
        k x =
            let
                y = x x
            in
            [ x, \v -> always 0 [ v, w ] ]
    in
    0
