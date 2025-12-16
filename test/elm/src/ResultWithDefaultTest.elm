module ResultWithDefaultTest exposing (main)

{-| Test Result.withDefault.
-}

-- CHECK: withDefault1: 42
-- CHECK: withDefault2: 0

import Html exposing (text)


main =
    let
        _ = Debug.log "withDefault1" (Result.withDefault 0 (Ok 42))
        _ = Debug.log "withDefault2" (Result.withDefault 0 (Err "error"))
    in
    text "done"
