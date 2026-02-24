module RoundTripStringTest exposing (main)

-- CHECK: rt_string: Ok "hello"

import Html exposing (text)
import Json.Decode as Decode
import Json.Encode as Encode

main =
    let
        _ = Debug.log "rt_string" (Decode.decodeString Decode.string (Encode.encode 0 (Encode.string "hello")))
    in
    text "done"
