module DecodeFieldTest exposing (main)

-- CHECK: decode_field: Ok "tom"

import Html exposing (text)
import Json.Decode as Decode

main =
    let
        _ = Debug.log "decode_field" (Decode.decodeString (Decode.field "name" Decode.string) "{\"name\":\"tom\"}")
    in
    text "done"
