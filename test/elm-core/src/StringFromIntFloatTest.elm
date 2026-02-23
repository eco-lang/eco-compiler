module StringFromIntFloatTest exposing (main)

-- CHECK: fromInt1: "42"
-- CHECK: fromFloat1: "3.14"
-- CHECK: fromChar1: "A"

import Html exposing (text)

main =
    let
        _ = Debug.log "fromInt1" (String.fromInt 42)
        _ = Debug.log "fromFloat1" (String.fromFloat 3.14)
        _ = Debug.log "fromChar1" (String.fromChar 'A')
    in
    text "done"
