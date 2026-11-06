module ContainerEqualityRecordFloatTest exposing (main)

{-| Checks `==` on records whose fields are `Float`, including NaN, infinities
and negative zero.

Record fields are compared with `Float` equality: `NaN` is unequal even to
itself, `-0.0` equals `0.0`, and `Infinity` equals itself but not `-Infinity`.
Records are not `comparable`, so only `==` is used.

  - Two-field records: equal, differing in each field, `0.0` against `-0.0`
    (True), NaN (False), the same infinity (True) and opposite infinities
    (False).
  - Three-field records: equal, differing in the middle, zeros of mixed sign
    (True), NaN in the middle (False), and infinities with mixed-sign zeros
    (True).

-}

-- CHECK: recEqual: True
-- CHECK: recXDiff: False
-- CHECK: recYDiff: False
-- CHECK: recNegZero: True
-- CHECK: recNaN: False
-- CHECK: recPosInf: True
-- CHECK: recInfSign: False
-- CHECK: rec3Equal: True
-- CHECK: rec3MidDiff: False
-- CHECK: rec3AllNegZero: True
-- CHECK: rec3NaNMid: False
-- CHECK: rec3MixedInf: True

import Html exposing (text)


main =
    let
        nan = 0.0 / 0.0
        posInf = 1.0 / 0.0
        negInf = -1.0 / 0.0

        -- Two-field record ----------------------------------------------
        _ = Debug.log "recEqual" ({ x = 1.5, y = 2.5 } == { x = 1.5, y = 2.5 })
        _ = Debug.log "recXDiff" ({ x = 1.5, y = 2.5 } == { x = 2.5, y = 2.5 })
        _ = Debug.log "recYDiff" ({ x = 1.5, y = 2.5 } == { x = 1.5, y = 3.5 })
        _ = Debug.log "recNegZero" ({ x = 0.0, y = 1.0 } == { x = -0.0, y = 1.0 })
        _ = Debug.log "recNaN" ({ x = nan, y = 1.0 } == { x = nan, y = 1.0 })
        _ = Debug.log "recPosInf" ({ x = posInf, y = 1.0 } == { x = posInf, y = 1.0 })
        _ = Debug.log "recInfSign" ({ x = posInf, y = 1.0 } == { x = negInf, y = 1.0 })

        -- Three-field record --------------------------------------------
        _ = Debug.log "rec3Equal" ({ a = 1.0, b = 2.0, c = 3.0 } == { a = 1.0, b = 2.0, c = 3.0 })
        _ = Debug.log "rec3MidDiff" ({ a = 1.0, b = 2.0, c = 3.0 } == { a = 1.0, b = 9.0, c = 3.0 })
        _ = Debug.log "rec3AllNegZero" ({ a = 0.0, b = -0.0, c = 0.0 } == { a = -0.0, b = 0.0, c = -0.0 })
        _ = Debug.log "rec3NaNMid" ({ a = 1.0, b = nan, c = 3.0 } == { a = 1.0, b = nan, c = 3.0 })
        _ = Debug.log "rec3MixedInf" ({ a = posInf, b = negInf, c = 0.0 } == { a = posInf, b = negInf, c = -0.0 })
    in
    text "done"
