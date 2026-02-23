module DecodeSucceedFailTest exposing (main)

-- CHECK: succeed1: Ok 99

import Html exposing (text)
import Json.Decode as Decode

main =
    let
        _ = Debug.log "succeed1" (Decode.decodeString (Decode.succeed 99) "null")
    in
    text "done"
