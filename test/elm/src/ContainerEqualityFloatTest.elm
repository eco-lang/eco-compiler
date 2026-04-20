module ContainerEqualityFloatTest exposing (main)

{-| Equality of Float-containing Tuple2, Tuple3, and List values.

    IEEE / Elm Float equality invariants exercised here:

      - `NaN == NaN` is False, and that propagates through every container:
        a NaN anywhere on either side makes the whole structural `==` False.
      - `-0.0 == 0.0` is True, and that too propagates through containers
        (so a pair of `-0.0`s equals a pair of `0.0`s).
      - `Infinity == Infinity` is True; `Infinity == -Infinity` is False.
-}

-- CHECK: pairEqual: True
-- CHECK: pairFirstDiff: False
-- CHECK: pairSecondDiff: False
-- CHECK: pairNegZero: True
-- CHECK: pairNaNFirst: False
-- CHECK: pairNaNSecond: False
-- CHECK: pairPosInf: True
-- CHECK: pairInfSignDiff: False
-- CHECK: tripleEqual: True
-- CHECK: tripleMidDiff: False
-- CHECK: tripleAllNegZero: True
-- CHECK: tripleNaNMid: False
-- CHECK: tripleMixedInf: True
-- CHECK: listEqual: True
-- CHECK: listLenDiff: False
-- CHECK: listEmpty: True
-- CHECK: listNegZero: True
-- CHECK: listNaN: False
-- CHECK: listInfPair: True
-- CHECK: listInfSignDiff: False

import Html exposing (text)


main =
    let
        nan = 0.0 / 0.0
        posInf = 1.0 / 0.0
        negInf = -1.0 / 0.0

        emptyFloats : List Float
        emptyFloats = []

        -- Tuple2 ---------------------------------------------------------
        _ = Debug.log "pairEqual" ((1.5, 2.5) == (1.5, 2.5))
        _ = Debug.log "pairFirstDiff" ((1.5, 2.5) == (1.6, 2.5))
        _ = Debug.log "pairSecondDiff" ((1.5, 2.5) == (1.5, 2.6))
        _ = Debug.log "pairNegZero" ((0.0, 1.0) == (-0.0, 1.0))
        _ = Debug.log "pairNaNFirst" ((nan, 1.0) == (nan, 1.0))
        _ = Debug.log "pairNaNSecond" ((1.0, nan) == (1.0, nan))
        _ = Debug.log "pairPosInf" ((posInf, 1.0) == (posInf, 1.0))
        _ = Debug.log "pairInfSignDiff" ((posInf, 1.0) == (negInf, 1.0))

        -- Tuple3 ---------------------------------------------------------
        _ = Debug.log "tripleEqual" ((1.0, 2.0, 3.0) == (1.0, 2.0, 3.0))
        _ = Debug.log "tripleMidDiff" ((1.0, 2.0, 3.0) == (1.0, 9.0, 3.0))
        _ = Debug.log "tripleAllNegZero" ((0.0, -0.0, 0.0) == (-0.0, 0.0, -0.0))
        _ = Debug.log "tripleNaNMid" ((1.0, nan, 3.0) == (1.0, nan, 3.0))
        _ = Debug.log "tripleMixedInf" ((posInf, negInf, 0.0) == (posInf, negInf, -0.0))

        -- List -----------------------------------------------------------
        _ = Debug.log "listEqual" ([1.0, 2.0, 3.0] == [1.0, 2.0, 3.0])
        _ = Debug.log "listLenDiff" ([1.0, 2.0] == [1.0, 2.0, 3.0])
        _ = Debug.log "listEmpty" (emptyFloats == [])
        _ = Debug.log "listNegZero" ([0.0, -0.0, 0.0] == [-0.0, 0.0, -0.0])
        _ = Debug.log "listNaN" ([1.0, nan, 3.0] == [1.0, nan, 3.0])
        _ = Debug.log "listInfPair" ([posInf, negInf] == [posInf, negInf])
        _ = Debug.log "listInfSignDiff" ([posInf, negInf] == [negInf, posInf])
    in
    text "done"
