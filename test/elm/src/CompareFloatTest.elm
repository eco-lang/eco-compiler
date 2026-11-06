module CompareFloatTest exposing (main)

{-| `compare` on `Float` returns `LT`, `GT` and `EQ` for less, greater and equal
operands.
-}

-- CHECK: cmp1: LT
-- CHECK: cmp2: GT
-- CHECK: cmp3: EQ

import Html exposing (text)


main =
    let
        _ = Debug.log "cmp1" (compare 1.5 2.5)
        _ = Debug.log "cmp2" (compare 3.14 2.71)
        _ = Debug.log "cmp3" (compare 5.0 5.0)
    in
    text "done"
