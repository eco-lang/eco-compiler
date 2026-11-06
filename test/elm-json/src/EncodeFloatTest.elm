module EncodeFloatTest exposing (main)

{-| `Json.Encode.float` writes zero, positive, negative and small fractional values as the
shortest JSON number text, and `1.5` survives a round trip through `Json.Decode.float`.

`0.0` encodes as `0`, with no fractional part; `3.14`, `-2.5` and `0.001` encode as written.
-}

-- CHECK: zero: "0"
-- CHECK: positive: "3.14"
-- CHECK: negative: "-2.5"
-- CHECK: small: "0.001"
-- CHECK: rt: Ok 1.5


import Html exposing (text)
import Json.Decode as Decode
import Json.Encode as Encode


main =
    let
        _ =
            Debug.log "zero" (Encode.encode 0 (Encode.float 0.0))

        _ =
            Debug.log "positive" (Encode.encode 0 (Encode.float 3.14))

        _ =
            Debug.log "negative" (Encode.encode 0 (Encode.float -2.5))

        _ =
            Debug.log "small" (Encode.encode 0 (Encode.float 0.001))

        _ =
            Debug.log "rt" (Decode.decodeString Decode.float (Encode.encode 0 (Encode.float 1.5)))
    in
    text "done"
