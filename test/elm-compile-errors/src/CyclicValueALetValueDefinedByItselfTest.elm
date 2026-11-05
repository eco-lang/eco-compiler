module CyclicValueALetValueDefinedByItselfTest exposing (..)

{-| CYCLIC VALUE: a let value defined by itself.

From `SourceIR.CanonicalizeFailsCases` (`testValue`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: CYCLIC VALUE, a let value defined by itself
-- CHECK: -- CYCLIC VALUE -
-- CHECK: `y`

testValue =
    let
        y =
            y + 1
    in
    y
