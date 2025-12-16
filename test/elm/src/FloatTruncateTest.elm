module FloatTruncateTest exposing (main)

{-| Test truncate function (toward zero).
-}

-- CHECK: trunc1: 2
-- CHECK: trunc2: 2
-- CHECK: trunc3: -2
-- CHECK: trunc4: -2

import Html exposing (text)


main =
    let
        _ = Debug.log "trunc1" (truncate 2.7)
        _ = Debug.log "trunc2" (truncate 2.3)
        _ = Debug.log "trunc3" (truncate -2.3)
        _ = Debug.log "trunc4" (truncate -2.7)
    in
    text "done"
