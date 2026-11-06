module RoundTripBoolTest exposing (main)

{-| `True` and `False` encoded with `Json.Encode.bool` decode back to the same values with `Json.Decode.bool`.
-}

-- CHECK: rt_true: Ok True
-- CHECK: rt_false: Ok False

import Html exposing (text)
import Json.Decode as Decode
import Json.Encode as Encode

main =
    let
        _ = Debug.log "rt_true" (Decode.decodeString Decode.bool (Encode.encode 0 (Encode.bool True)))
        _ = Debug.log "rt_false" (Decode.decodeString Decode.bool (Encode.encode 0 (Encode.bool False)))
    in
    text "done"
