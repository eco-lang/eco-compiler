module DecodeListTest exposing (main)

{-| `Json.Decode.list` decodes a JSON array of numbers to a `List Int`.
-}

-- CHECK: decode_list: Ok [1,2,3]

import Html exposing (text)
import Json.Decode as Decode

main =
    let
        _ = Debug.log "decode_list" (Decode.decodeString (Decode.list Decode.int) "[1,2,3]")
    in
    text "done"
