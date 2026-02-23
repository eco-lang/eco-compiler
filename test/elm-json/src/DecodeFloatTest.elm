module DecodeFloatTest exposing (main)

-- CHECK: decode_float: Ok 3.14

import Html exposing (text)
import Json.Decode as Decode

main =
    let
        _ = Debug.log "decode_float" (Decode.decodeString Decode.float "3.14")
    in
    text "done"
