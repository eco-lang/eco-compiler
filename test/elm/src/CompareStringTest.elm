module CompareStringTest exposing (main)

{-| `compare` on `String` returns `LT`, `GT` and `EQ` for strings that are less
than, greater than and equal to one another, comparing character codes from the
first character.
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
