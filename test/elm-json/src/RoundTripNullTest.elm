module RoundTripNullTest exposing (main)

-- CHECK: rt_null: Ok 0

import Html exposing (text)
import Json.Decode as Decode
import Json.Encode as Encode

main =
    let
        _ = Debug.log "rt_null" (Decode.decodeString (Decode.null 0) (Encode.encode 0 Encode.null))
    in
    text "done"
