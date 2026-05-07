module EncodeFloatTest exposing (main)

{-| `Json.Encode.float` calls `Json.wrap` which is migrated in Phase C to
    `Elm_Kernel_Json_wrap_Float` for `Float` operands. Tests the new
    Custom-allocation path doesn't drop precision and round-trips through
    Decode.float intact.
-}

-- CHECK: zero: "0.0"
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
