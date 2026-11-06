module FloatTruncateTest exposing (main)

{-| `truncate` rounds a Float toward zero: 2.7 and 2.3 give 2, and -2.3 and -2.7 give -2.
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
