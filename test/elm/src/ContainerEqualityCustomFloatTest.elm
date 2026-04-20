module ContainerEqualityCustomFloatTest exposing (main)

{-| Equality of custom types whose fields are Float, including NaN, Infinity,
    and +/- 0.0.

    Custom types are not Elm `comparable`, so only `==` is exercised. This
    test targets the `Tag_Custom` branch of `Utils_equal`, which reads
    unboxed fields via `.i` (bit compare) rather than IEEE equality.
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
