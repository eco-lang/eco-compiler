module DecodeIndexTest exposing (main)

-- CHECK: decode_index: Ok "world"

import Html exposing (text)
import Json.Decode as Decode

main =
    let
        _ = Debug.log "decode_index" (Decode.decodeString (Decode.index 1 Decode.string) "[\"hello\",\"world\"]")
    in
    text "done"
