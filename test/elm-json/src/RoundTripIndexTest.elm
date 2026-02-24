module RoundTripIndexTest exposing (main)

-- CHECK: rt_index: Ok "world"

import Html exposing (text)
import Json.Decode as Decode
import Json.Encode as Encode

main =
    let
        json = Encode.encode 0 (Encode.list Encode.string [ "hello", "world" ])
        _ = Debug.log "rt_index" (Decode.decodeString (Decode.index 1 Decode.string) json)
    in
    text "done"
