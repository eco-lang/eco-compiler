module InfiniteTypeSelfAppliedArgumentOnBothSidesTest exposing (..)

{-| INFINITE TYPE: self-applied argument on both sides.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: INFINITE TYPE, self-applied argument on both sides
-- CHECK: -- INFINITE TYPE -
-- CHECK: ∞

k x =
    let
        y = x x
    in
    [ ( x, 1 ), ( x, "a" ) ]
