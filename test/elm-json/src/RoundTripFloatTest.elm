module RoundTripFloatTest exposing (main)

-- CHECK: rt_float: Ok 3.14

import Html exposing (text)
import Json.Decode as Decode
import Json.Encode as Encode

main =
    let
        _ = Debug.log "rt_float" (Decode.decodeString Decode.float (Encode.encode 0 (Encode.float 3.14)))
    in
    text "done"
