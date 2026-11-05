module TypeMismatchDestructureTest exposing (..)

{-| TYPE MISMATCH: destructure.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, destructure
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Only Int and Float values work as numbers.

x =
    let
        ( a, b ) = 1
    in
    a
