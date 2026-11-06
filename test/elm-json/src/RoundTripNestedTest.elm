module RoundTripNestedTest exposing (main)

{-| `Json.Decode.at [ "a", "b" ]` reads the integer 42 from an object nested inside another object.
-}

-- CHECK: rt_nested: Ok 42

import Html exposing (text)
import Json.Decode as Decode
import Json.Encode as Encode

main =
    let
        json = Encode.encode 0 (Encode.object [ ( "a", Encode.object [ ( "b", Encode.int 42 ) ] ) ])
        _ = Debug.log "rt_nested" (Decode.decodeString (Decode.at [ "a", "b" ] Decode.int) json)
    in
    text "done"
