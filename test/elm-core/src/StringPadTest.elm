module StringPadTest exposing (main)

-- CHECK: padLeft1: "  hi"
-- CHECK: padRight1: "hi  "
-- CHECK: padLeft_char: "00042"

import Html exposing (text)

main =
    let
        _ = Debug.log "padLeft1" (String.padLeft 4 ' ' "hi")
        _ = Debug.log "padRight1" (String.padRight 4 ' ' "hi")
        _ = Debug.log "padLeft_char" (String.padLeft 5 '0' "42")
    in
    text "done"
