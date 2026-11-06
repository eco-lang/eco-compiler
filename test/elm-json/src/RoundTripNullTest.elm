module RoundTripNullTest exposing (main)

{-| `Json.Encode.null` decodes with `Json.Decode.null 0` to 0, the value passed to `null`.
-}

-- CHECK: rt_null: Ok 0

import Html exposing (text)
import Json.Decode as Decode
import Json.Encode as Encode

main =
    let
        _ = Debug.log "rt_null" (Decode.decodeString (Decode.null 0) (Encode.encode 0 Encode.null))
    in
    text "done"
