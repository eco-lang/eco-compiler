module CompareCharTest exposing (main)

{-| Test compare on Char.
-}

-- CHECK: cmp1: LT
-- CHECK: cmp2: GT
-- CHECK: cmp3: EQ

import Html exposing (text)


main =
    let
        _ = Debug.log "cmp1" (compare 'a' 'b')
        _ = Debug.log "cmp2" (compare 'z' 'a')
        _ = Debug.log "cmp3" (compare 'x' 'x')
    in
    text "done"
