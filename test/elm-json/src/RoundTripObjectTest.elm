module RoundTripObjectTest exposing (main)

-- CHECK: rt_object: Ok "tom"

import Html exposing (text)
import Json.Decode as Decode
import Json.Encode as Encode

main =
    let
        json = Encode.encode 0 (Encode.object [ ( "name", Encode.string "tom" ) ])
        _ = Debug.log "rt_object" (Decode.decodeString (Decode.field "name" Decode.string) json)
    in
    text "done"
