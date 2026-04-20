module ContainerEqualityIntTest exposing (main)

{-| Equality of Int-containing Tuple2, Tuple3, and List values.

    Int has no IEEE quirks, so the interesting cases are around the sign of
    each element and around list length.
-}

-- CHECK: pairEqual: True
-- CHECK: pairFirstDiff: False
-- CHECK: pairSecondDiff: False
-- CHECK: pairNegatives: True
-- CHECK: pairSignDiff: False
-- CHECK: pairZero: True
-- CHECK: tripleEqual: True
-- CHECK: tripleMidDiff: False
-- CHECK: tripleSignMix: True
-- CHECK: tripleMinMax: True
-- CHECK: listEqual: True
-- CHECK: listLenDiff: False
-- CHECK: listPrefixExtra: False
-- CHECK: listEmpty: True
-- CHECK: listNegatives: True
-- CHECK: listSignMix: True

import Html exposing (text)


main =
    let
        emptyInts : List Int
        emptyInts = []

        -- Tuple2 ---------------------------------------------------------
        _ = Debug.log "pairEqual" ((1, 2) == (1, 2))
        _ = Debug.log "pairFirstDiff" ((1, 2) == (3, 2))
        _ = Debug.log "pairSecondDiff" ((1, 2) == (1, 3))
        _ = Debug.log "pairNegatives" ((-7, -8) == (-7, -8))
        _ = Debug.log "pairSignDiff" ((-1, 2) == (1, 2))
        _ = Debug.log "pairZero" ((0, 0) == (0, 0))

        -- Tuple3 ---------------------------------------------------------
        _ = Debug.log "tripleEqual" ((1, 2, 3) == (1, 2, 3))
        _ = Debug.log "tripleMidDiff" ((1, 2, 3) == (1, 9, 3))
        _ = Debug.log "tripleSignMix" ((-1, 0, 1) == (-1, 0, 1))
        _ = Debug.log "tripleMinMax" ((-2147483648, 0, 2147483647) == (-2147483648, 0, 2147483647))

        -- List -----------------------------------------------------------
        _ = Debug.log "listEqual" ([1, 2, 3] == [1, 2, 3])
        _ = Debug.log "listLenDiff" ([1, 2] == [1, 2, 3])
        _ = Debug.log "listPrefixExtra" ([1, 2, 3] == [1, 2])
        _ = Debug.log "listEmpty" (emptyInts == [])
        _ = Debug.log "listNegatives" ([-3, -2, -1] == [-3, -2, -1])
        _ = Debug.log "listSignMix" ([-1, 0, 1] == [-1, 0, 1])
    in
    text "done"
