module EncodeIntTest exposing (main)

{-| `Json.Encode.int` calls `Json.wrap` which is migrated in Phase C to
    `Elm_Kernel_Json_wrap_Int` for `Int` operands.
-}

-- CHECK: zero: "0"
-- CHECK: positive: "42"
-- CHECK: negative: "-7"
-- CHECK: max_i32: "2147483647"
-- CHECK: min_i32: "-2147483648"


import Html exposing (text)
import Json.Encode as Encode


main =
    let
        _ =
            Debug.log "zero" (Encode.encode 0 (Encode.int 0))

        _ =
            Debug.log "positive" (Encode.encode 0 (Encode.int 42))

        _ =
            Debug.log "negative" (Encode.encode 0 (Encode.int -7))

        _ =
            Debug.log "max_i32" (Encode.encode 0 (Encode.int 2147483647))

        _ =
            Debug.log "min_i32" (Encode.encode 0 (Encode.int -2147483648))
    in
    text "done"
