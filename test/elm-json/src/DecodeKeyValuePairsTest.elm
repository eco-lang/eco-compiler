module DecodeKeyValuePairsTest exposing (main)

-- CHECK: kvp1: Ok [("a", 1), ("b", 2)]

import Html exposing (text)
import Json.Decode as Decode

main =
    let
        _ = Debug.log "kvp1" (Decode.decodeString (Decode.keyValuePairs Decode.int) "{\"a\":1,\"b\":2}")
    in
    text "done"
