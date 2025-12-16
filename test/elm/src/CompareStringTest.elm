module CompareStringTest exposing (main)

{-| Test compare on String.
-}

-- CHECK: cmp1: LT
-- CHECK: cmp2: GT
-- CHECK: cmp3: EQ

import Html exposing (text)


main =
    let
        _ = Debug.log "cmp1" (compare "apple" "banana")
        _ = Debug.log "cmp2" (compare "zebra" "ant")
        _ = Debug.log "cmp3" (compare "hello" "hello")
    in
    text "done"
