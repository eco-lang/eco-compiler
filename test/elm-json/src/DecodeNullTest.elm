module DecodeNullTest exposing (main)

{-| `Json.Decode.null 0` decodes the JSON literal `null` to the given value `0`.
-}

-- CHECK: decode_null: Ok 0

import Html exposing (text)
import Json.Decode as Decode

main =
    let
        _ = Debug.log "decode_null" (Decode.decodeString (Decode.null 0) "null")
    in
    text "done"
