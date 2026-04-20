module ContainerEqualityRecordFloatTest exposing (main)

{-| Equality of records whose fields are Float, including NaN, Infinity, and
    +/- 0.0.

    Records are not Elm `comparable`, so only `==` is exercised (no `compare`
    or relational operators). Same IEEE/Elm invariants as the tuple tests:

      - `NaN == NaN` is False everywhere, including inside a record.
      - `-0.0 == 0.0` is True everywhere, including inside a record.
      - `Infinity == Infinity` is True; `Infinity == -Infinity` is False.

    This test targets the `Tag_Record` branch of `Utils_equal`, which reads
    unboxed fields via `.i` (bit compare) rather than IEEE equality.
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
