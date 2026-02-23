module DecodeAtTest exposing (main)

-- CHECK: decode_at: Ok 42

import Html exposing (text)
import Json.Decode as Decode

main =
    let
        _ = Debug.log "decode_at" (Decode.decodeString (Decode.at ["a", "b"] Decode.int) "{\"a\":{\"b\":42}}")
    in
    text "done"
