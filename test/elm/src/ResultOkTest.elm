module ResultOkTest exposing (main)

{-| Test Ok creation.
-}

-- CHECK: ok1: Ok 42
-- CHECK: ok2: Ok "success"

import Html exposing (text)


main =
    let
        _ = Debug.log "ok1" (Ok 42)
        _ = Debug.log "ok2" (Ok "success")
    in
    text "done"
