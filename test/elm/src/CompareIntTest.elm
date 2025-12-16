module CompareIntTest exposing (main)

{-| Test compare on Int.
-}

-- CHECK: cmp1: LT
-- CHECK: cmp2: GT
-- CHECK: cmp3: EQ

import Html exposing (text)


main =
    let
        _ = Debug.log "cmp1" (compare 1 2)
        _ = Debug.log "cmp2" (compare 3 2)
        _ = Debug.log "cmp3" (compare 5 5)
    in
    text "done"
