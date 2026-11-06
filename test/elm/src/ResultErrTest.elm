module ResultErrTest exposing (main)

{-| Checks that `Err` builds a `Result` around a `String` and around an `Int`, and that `Debug.log` prints them as `Err "failed"` and `Err 404`.
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
