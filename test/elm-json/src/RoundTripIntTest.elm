module RoundTripIntTest exposing (main)

{-| The integer 42 encoded with `Json.Encode.int` decodes back to 42 with `Json.Decode.int`.
-}

-- CHECK: rt_int: Ok 42

import Html exposing (text)
import Json.Decode as Decode
import Json.Encode as Encode

main =
    let
        _ = Debug.log "rt_int" (Decode.decodeString Decode.int (Encode.encode 0 (Encode.int 42)))
    in
    text "done"
