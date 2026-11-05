module TypeMismatchSelfAppliedArgumentAgainstANumberTest exposing (..)

{-| TYPE MISMATCH: self-applied argument against a number.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, self-applied argument against a number
-- CHECK: -- TYPE MISMATCH -

k x =
    let
        y = x x
    in
    [ x, \v -> v + 1 ]
