module DecodeIntTest exposing (main)

{-| `Json.Decode.int` decodes the JSON number `42` to the `Int` `42`.
-}

-- CHECK: decode_int: Ok 42

import Html exposing (text)
import Json.Decode as Decode

main =
    let
        _ = Debug.log "decode_int" (Decode.decodeString Decode.int "42")
    in
    text "done"
