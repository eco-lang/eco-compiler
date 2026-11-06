module ResultOkTest exposing (main)

{-| Checks that `Ok` builds a `Result` around an `Int` and around a `String`, and that `Debug.log` prints them as `Ok 42` and `Ok "success"`.
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
