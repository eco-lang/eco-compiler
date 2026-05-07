module StringFromNumberFloatTest exposing (main)

{-| `String.fromFloat` calls `String.fromNumber` which is migrated in
    Phase C to `Elm_Kernel_String_fromNumber_Float`.
-}

-- CHECK: zero: "0"
-- CHECK: positive: "3.14"
-- CHECK: negative: "-2.5"
-- CHECK: small: "0.001"
-- CHECK: integer_valued: "42"


import Html exposing (text)


main =
    let
        _ =
            Debug.log "zero" (String.fromFloat 0.0)

        _ =
            Debug.log "positive" (String.fromFloat 3.14)

        _ =
            Debug.log "negative" (String.fromFloat -2.5)

        _ =
            Debug.log "small" (String.fromFloat 0.001)

        _ =
            Debug.log "integer_valued" (String.fromFloat 42.0)
    in
    text "done"
