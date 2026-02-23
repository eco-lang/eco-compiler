module StringTrimTest exposing (main)

-- CHECK: trim1: "hello"
-- CHECK: trimLeft1: "hello  "
-- CHECK: trimRight1: "  hello"

import Html exposing (text)

main =
    let
        _ = Debug.log "trim1" (String.trim "  hello  ")
        _ = Debug.log "trimLeft1" (String.trimLeft "  hello  ")
        _ = Debug.log "trimRight1" (String.trimRight "  hello  ")
    in
    text "done"
