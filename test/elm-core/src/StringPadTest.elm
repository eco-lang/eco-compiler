module StringPadTest exposing (main)

{-| Checks that `String.padLeft` and `String.padRight` pad a string to the requested length with the given character.
-}

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
