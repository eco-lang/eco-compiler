module ResultErrTest exposing (main)

{-| Test Err creation.
-}

-- CHECK: err1: Err "failed"
-- CHECK: err2: Err 404

import Html exposing (text)


main =
    let
        _ = Debug.log "err1" (Err "failed")
        _ = Debug.log "err2" (Err 404)
    in
    text "done"
