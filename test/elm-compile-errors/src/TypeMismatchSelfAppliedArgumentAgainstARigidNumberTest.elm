module TypeMismatchSelfAppliedArgumentAgainstARigidNumberTest exposing (..)

{-| TYPE MISMATCH: self-applied argument against a rigid number.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, self-applied argument against a rigid number
-- CHECK: -- TYPE MISMATCH -
-- CHECK: ∞

h : number -> Int
h w =
    let
        k x =
            let
                y = x x
            in
            [ x, \v -> always 0 [ v, w ] ]
    in
    0
