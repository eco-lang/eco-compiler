module DecodeStringTest exposing (main)

-- CHECK: decode_string: Ok "hello"

import Html exposing (text)
import Json.Decode as Decode

main =
    let
        _ = Debug.log "decode_string" (Decode.decodeString Decode.string "\"hello\"")
    in
    text "done"
