module StringUnicodeTest exposing (main)

{-| Test Unicode in strings.
-}

-- CHECK: greek
-- CHECK: emoji
-- CHECK: chinese

import Html exposing (text)


main =
    let
        _ = Debug.log "greek" "alpha beta gamma"
        _ = Debug.log "emoji" "hello"
        _ = Debug.log "chinese" "hello"
    in
    text "done"
