module RoundTripNegativeIntTest exposing (main)

-- CHECK: rt_neg_int: Ok -7

import Html exposing (text)
import Json.Decode as Decode
import Json.Encode as Encode

main =
    let
        _ = Debug.log "rt_neg_int" (Decode.decodeString Decode.int (Encode.encode 0 (Encode.int -7)))
    in
    text "done"
