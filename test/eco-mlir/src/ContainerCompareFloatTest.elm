module ContainerCompareFloatTest exposing (main)

{-| Ordering of pairs, triples and lists of `Float` with `compare` and the
relational operators.

The edge values covered:

  - `-0.0` and `0.0` compare `EQ` inside a container.
  - Positive infinity is greater than `1.0e300`, and negative infinity is less
    than `-1.0e300`; containers holding them order by them.
  - NaN is not used: `compare` gives no meaningful order for it.

## eco

The TEXT-MLIR directive compiles this test through the textual MLIR printer
(compiler/src/Mlir/Pretty.elm) rather than the default path, so the printer stays covered and
checked end to end. Container comparison of `Float` elements also exercises unboxed `Float`
fields in tuple and list cells (REP_HEAP_002 in design_docs/invariants.csv).

-}

-- TEXT-MLIR: also keeps the MLIR text printer (Mlir.Pretty) covered and checked end to end
-- CHECK: pairLt: LT
-- CHECK: pairGt: GT
-- CHECK: pairEq: EQ
-- CHECK: pairSecondDecides: LT
-- CHECK: pairNegZeroEq: EQ
-- CHECK: pairPosInfBeatsFinite: GT
-- CHECK: pairNegInfLosesFinite: LT
-- CHECK: pairBothInfEq: EQ
-- CHECK: tripleFirstDecides: LT
-- CHECK: tripleThirdDecides: GT
-- CHECK: tripleEq: EQ
-- CHECK: tripleInf: LT
-- CHECK: listLt: LT
-- CHECK: listShorterIsLess: LT
-- CHECK: listEq: EQ
-- CHECK: listEmptyIsLeast: LT
-- CHECK: listNegZeroEq: EQ
-- CHECK: listInf: LT
-- CHECK: pairLtOp: True
-- CHECK: pairGeOp: True
-- CHECK: tripleLtOp: True
-- CHECK: listGtOp: True

import Html exposing (text)


main =
    let
        posInf = 1.0 / 0.0
        negInf = -1.0 / 0.0

        emptyFloats : List Float
        emptyFloats = []

        -- Tuple2 ---------------------------------------------------------
        _ = Debug.log "pairLt" (compare (1.0, 2.0) (1.0, 3.0))
        _ = Debug.log "pairGt" (compare (2.0, 0.0) (1.0, 9.0))
        _ = Debug.log "pairEq" (compare (1.5, 2.5) (1.5, 2.5))
        _ = Debug.log "pairSecondDecides" (compare (1.0, 2.0) (1.0, 2.5))
        _ = Debug.log "pairNegZeroEq" (compare (0.0, -0.0) (-0.0, 0.0))
        _ = Debug.log "pairPosInfBeatsFinite" (compare (posInf, 0.0) (1.0e300, 0.0))
        _ = Debug.log "pairNegInfLosesFinite" (compare (negInf, 0.0) (-1.0e300, 0.0))
        _ = Debug.log "pairBothInfEq" (compare (posInf, negInf) (posInf, negInf))

        -- Tuple3 ---------------------------------------------------------
        _ = Debug.log "tripleFirstDecides" (compare (1.0, 9.0, 9.0) (2.0, 0.0, 0.0))
        _ = Debug.log "tripleThirdDecides" (compare (1.0, 2.0, 5.0) (1.0, 2.0, 4.0))
        _ = Debug.log "tripleEq" (compare (1.0, 2.0, 3.0) (1.0, 2.0, 3.0))
        _ = Debug.log "tripleInf" (compare (negInf, 0.0, 0.0) (posInf, 0.0, 0.0))

        -- List -----------------------------------------------------------
        _ = Debug.log "listLt" (compare [1.0, 2.0] [1.0, 3.0])
        _ = Debug.log "listShorterIsLess" (compare [1.0, 2.0] [1.0, 2.0, 0.0])
        _ = Debug.log "listEq" (compare [1.0, 2.0, 3.0] [1.0, 2.0, 3.0])
        _ = Debug.log "listEmptyIsLeast" (compare emptyFloats [ -1.0e300 ])
        _ = Debug.log "listNegZeroEq" (compare [0.0, -0.0, 0.0] [-0.0, 0.0, -0.0])
        _ = Debug.log "listInf" (compare [negInf, 0.0] [posInf, 0.0])

        -- Relational operators ------------------------------------------
        _ = Debug.log "pairLtOp" ((1.0, 2.0) < (1.0, 3.0))
        _ = Debug.log "pairGeOp" ((1.5, 2.5) >= (1.5, 2.5))
        _ = Debug.log "tripleLtOp" ((1.0, 2.0, 3.0) < (1.0, 2.0, 4.0))
        _ = Debug.log "listGtOp" ([2.0, 0.0] > [1.0, 9.0])
    in
    text "done"
