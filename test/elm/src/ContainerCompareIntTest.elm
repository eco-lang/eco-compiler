module ContainerCompareIntTest exposing (main)

{-| Ordering of Int-containing Tuple2, Tuple3, and List values via `compare`
    and the relational operators.

    Focus areas: lex order across positions, negatives vs positives, the
    shorter-is-less rule on lists, and the empty list as the least list.
-}

-- CHECK: pairLt: LT
-- CHECK: pairGt: GT
-- CHECK: pairEq: EQ
-- CHECK: pairSecondDecides: LT
-- CHECK: pairNegFirst: LT
-- CHECK: pairNegSecond: GT
-- CHECK: tripleFirstDecides: LT
-- CHECK: tripleThirdDecides: GT
-- CHECK: tripleEq: EQ
-- CHECK: tripleNegMix: LT
-- CHECK: listLt: LT
-- CHECK: listShorterIsLess: LT
-- CHECK: listEq: EQ
-- CHECK: listEmptyIsLeast: LT
-- CHECK: listNegVsPos: LT
-- CHECK: pairLtOp: True
-- CHECK: pairGeOp: True
-- CHECK: tripleLtOp: True
-- CHECK: listGtOp: True

import Html exposing (text)


main =
    let
        emptyInts : List Int
        emptyInts = []

        -- Tuple2 ---------------------------------------------------------
        _ = Debug.log "pairLt" (compare (1, 2) (1, 3))
        _ = Debug.log "pairGt" (compare (2, 0) (1, 9))
        _ = Debug.log "pairEq" (compare (5, 5) (5, 5))
        _ = Debug.log "pairSecondDecides" (compare (1, 2) (1, 5))
        _ = Debug.log "pairNegFirst" (compare (-5, 0) (1, 0))
        _ = Debug.log "pairNegSecond" (compare (0, -1) (0, -5))

        -- Tuple3 ---------------------------------------------------------
        _ = Debug.log "tripleFirstDecides" (compare (1, 9, 9) (2, 0, 0))
        _ = Debug.log "tripleThirdDecides" (compare (1, 2, 5) (1, 2, 4))
        _ = Debug.log "tripleEq" (compare (1, 2, 3) (1, 2, 3))
        _ = Debug.log "tripleNegMix" (compare (-1, 0, 1) (0, -1, 1))

        -- List -----------------------------------------------------------
        _ = Debug.log "listLt" (compare [1, 2] [1, 3])
        _ = Debug.log "listShorterIsLess" (compare [1, 2] [1, 2, 0])
        _ = Debug.log "listEq" (compare [1, 2, 3] [1, 2, 3])
        _ = Debug.log "listEmptyIsLeast" (compare emptyInts [-2147483648])
        _ = Debug.log "listNegVsPos" (compare [-1, 0] [1, 0])

        -- Relational operators ------------------------------------------
        _ = Debug.log "pairLtOp" ((1, 2) < (1, 3))
        _ = Debug.log "pairGeOp" ((5, 5) >= (5, 5))
        _ = Debug.log "tripleLtOp" ((1, 2, 3) < (1, 2, 4))
        _ = Debug.log "listGtOp" ([2, 0] > [1, 9])
    in
    text "done"
