module DecodeStringTest exposing (main)

{-| `Json.Decode.string` decodes a JSON string literal to the Elm `String` it contains.
-}

-- CHECK: decode_string: Ok "hello"

import Html exposing (text)
import Json.Decode as Decode

main =
    let
        _ = Debug.log "decode_string" (Decode.decodeString Decode.string "\"hello\"")
    in
    text "done"
