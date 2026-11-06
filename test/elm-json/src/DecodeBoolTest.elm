module DecodeBoolTest exposing (main)

{-| `Json.Decode.bool` decodes the JSON literals `true` and `false` to `True` and `False`.
-}

-- CHECK: decode_true: Ok True
-- CHECK: decode_false: Ok False

import Html exposing (text)
import Json.Decode as Decode

main =
    let
        _ = Debug.log "decode_true" (Decode.decodeString Decode.bool "true")
        _ = Debug.log "decode_false" (Decode.decodeString Decode.bool "false")
    in
    text "done"
