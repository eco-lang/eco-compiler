module DecodeAtTest exposing (main)

{-| `Json.Decode.at [ "a", "b" ]` follows nested object fields and decodes the value found there.
-}

-- CHECK: decode_at: Ok 42

import Html exposing (text)
import Json.Decode as Decode

main =
    let
        _ = Debug.log "decode_at" (Decode.decodeString (Decode.at ["a", "b"] Decode.int) "{\"a\":{\"b\":42}}")
    in
    text "done"
