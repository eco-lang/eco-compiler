module DecodeListTest exposing (main)

-- CHECK: decode_list: Ok [1, 2, 3]

import Html exposing (text)
import Json.Decode as Decode

main =
    let
        _ = Debug.log "decode_list" (Decode.decodeString (Decode.list Decode.int) "[1,2,3]")
    in
    text "done"
