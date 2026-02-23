module DecodeIntTest exposing (main)

-- CHECK: decode_int: Ok 42

import Html exposing (text)
import Json.Decode as Decode

main =
    let
        _ = Debug.log "decode_int" (Decode.decodeString Decode.int "42")
    in
    text "done"
