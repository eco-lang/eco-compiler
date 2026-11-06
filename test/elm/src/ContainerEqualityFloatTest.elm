module ContainerEqualityFloatTest exposing (main)

{-| Checks `==` on pairs, triples and lists of `Float`, including NaN,
infinities and negative zero.

`Float` equality inside a container is the same as outside it: `NaN == NaN` is
False, so a container holding NaN is unequal even to an identical container;
`-0.0 == 0.0` is True, so `[ 0.0, -0.0 ]` equals `[ -0.0, 0.0 ]`; and
`Infinity` equals itself but not `-Infinity`.

  - Pairs: equal, differing in either position, `0.0` against `-0.0`, NaN in
    either position, and infinities of the same and of opposite sign.
  - Triples: equal, differing in the middle, zeros of mixed sign, NaN in the
    middle, and infinities with mixed-sign zeros.
  - Lists: equal, different lengths, two empty lists, zeros of mixed sign, NaN,
    the same infinities, and the infinities in swapped order.

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
