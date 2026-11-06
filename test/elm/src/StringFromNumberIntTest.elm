module StringFromNumberIntTest exposing (main)

{-| `String.fromInt` prints zero, positive and negative integers, including the 32-bit
signed limits `2147483647` and `-2147483648`.
-}

-- CHECK: zero: "0"
-- CHECK: positive: "12345"
-- CHECK: negative: "-67"
-- CHECK: max_i32: "2147483647"
-- CHECK: min_i32: "-2147483648"


import Html exposing (text)


main =
    let
        _ =
            Debug.log "zero" (String.fromInt 0)

        _ =
            Debug.log "positive" (String.fromInt 12345)

        _ =
            Debug.log "negative" (String.fromInt -67)

        _ =
            Debug.log "max_i32" (String.fromInt 2147483647)

        _ =
            Debug.log "min_i32" (String.fromInt -2147483648)
    in
    text "done"
