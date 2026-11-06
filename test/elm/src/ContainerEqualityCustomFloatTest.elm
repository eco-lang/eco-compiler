module ContainerEqualityCustomFloatTest exposing (main)

{-| Checks `==` on custom-type values whose fields are `Float`, including NaN,
infinities and negative zero.

A constructor's fields are compared with `Float` equality, so `NaN` is unequal
even to itself, `-0.0` equals `0.0`, and the two infinities differ from each
other. Custom types are not `comparable`, so only `==` is used.

  - `Point` (two fields): equal, differing in each field, `0.0` against `-0.0`
    (True), NaN in either field (False), positive infinity on both sides (True)
    and opposite infinities (False).
  - `Triple` (three fields): equal, differing in the middle, zeros of mixed
    sign (True), NaN in the middle (False), and infinities with mixed-sign zeros
    (True).
  - Two different constructors of `Shape` with the same payload (False).

-}

-- CHECK: ptEqual: True
-- CHECK: ptXDiff: False
-- CHECK: ptYDiff: False
-- CHECK: ptNegZero: True
-- CHECK: ptNaNFirst: False
-- CHECK: ptNaNSecond: False
-- CHECK: ptPosInf: True
-- CHECK: ptInfSign: False
-- CHECK: triEqual: True
-- CHECK: triMidDiff: False
-- CHECK: triAllNegZero: True
-- CHECK: triNaNMid: False
-- CHECK: triMixedInf: True
-- CHECK: mixedCtorDiff: False

import Html exposing (text)


type Point
    = Point Float Float


type Triple
    = Triple Float Float Float


type Shape
    = Circle Float
    | Square Float


main =
    let
        nan = 0.0 / 0.0
        posInf = 1.0 / 0.0
        negInf = -1.0 / 0.0

        -- Two-field custom type -----------------------------------------
        _ = Debug.log "ptEqual" (Point 1.5 2.5 == Point 1.5 2.5)
        _ = Debug.log "ptXDiff" (Point 1.5 2.5 == Point 2.5 2.5)
        _ = Debug.log "ptYDiff" (Point 1.5 2.5 == Point 1.5 3.5)
        _ = Debug.log "ptNegZero" (Point 0.0 1.0 == Point -0.0 1.0)
        _ = Debug.log "ptNaNFirst" (Point nan 1.0 == Point nan 1.0)
        _ = Debug.log "ptNaNSecond" (Point 1.0 nan == Point 1.0 nan)
        _ = Debug.log "ptPosInf" (Point posInf 1.0 == Point posInf 1.0)
        _ = Debug.log "ptInfSign" (Point posInf 1.0 == Point negInf 1.0)

        -- Three-field custom type ---------------------------------------
        _ = Debug.log "triEqual" (Triple 1.0 2.0 3.0 == Triple 1.0 2.0 3.0)
        _ = Debug.log "triMidDiff" (Triple 1.0 2.0 3.0 == Triple 1.0 9.0 3.0)
        _ = Debug.log "triAllNegZero" (Triple 0.0 -0.0 0.0 == Triple -0.0 0.0 -0.0)
        _ = Debug.log "triNaNMid" (Triple 1.0 nan 3.0 == Triple 1.0 nan 3.0)
        _ = Debug.log "triMixedInf" (Triple posInf negInf 0.0 == Triple posInf negInf -0.0)

        -- Different constructors should never be equal even with same payload
        _ = Debug.log "mixedCtorDiff" (Circle 1.0 == Square 1.0)
    in
    text "done"
