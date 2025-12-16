module IntOverflowTest exposing (main)

{-| Test integer overflow behavior.
-}

-- CHECK: overflow

import Html exposing (text)


main =
    let
        big = 9223372036854775807
        _ = Debug.log "overflow" (big + 1)
    in
    text "done"
