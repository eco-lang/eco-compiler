module DecodeKeyValuePairsTest exposing (main)

{-| `Json.Decode.keyValuePairs` decodes a JSON object to a list of (key, value) pairs, here in the
order the keys appear in the input.
-}

-- CHECK: kvp1: Ok [("a",1),("b",2)]

import Html exposing (text)
import Json.Decode as Decode

main =
    let
        _ = Debug.log "kvp1" (Decode.decodeString (Decode.keyValuePairs Decode.int) "{\"a\":1,\"b\":2}")
    in
    text "done"
