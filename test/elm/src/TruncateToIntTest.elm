module TruncateToIntTest exposing (main)

{-| Test truncate for Float to Int conversion.
-}

-- CHECK: trunc1: 2
-- CHECK: trunc2: -2

import Html exposing (text)


main =
    let
        _ = Debug.log "trunc1" (truncate 2.7)
        _ = Debug.log "trunc2" (truncate -2.7)
    in
    text "done"
