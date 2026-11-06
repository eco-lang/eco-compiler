module RoundTripKeyValuePairsTest exposing (main)

{-| `Json.Decode.keyValuePairs` decodes an object encoded from `[ ( "a", 1 ), ( "b", 2 ) ]` back to the same pairs, in the same order.
-}

-- CHECK: rt_kvp: Ok [("a",1),("b",2)]

import Html exposing (text)
import Json.Decode as Decode
import Json.Encode as Encode

main =
    let
        json = Encode.encode 0 (Encode.object [ ( "a", Encode.int 1 ), ( "b", Encode.int 2 ) ])
        _ = Debug.log "rt_kvp" (Decode.decodeString (Decode.keyValuePairs Decode.int) json)
    in
    text "done"
