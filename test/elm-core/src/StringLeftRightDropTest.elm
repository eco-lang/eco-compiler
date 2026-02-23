module StringLeftRightDropTest exposing (main)

-- CHECK: left1: "Hel"
-- CHECK: right1: "llo"
-- CHECK: dropLeft1: "lo"
-- CHECK: dropRight1: "Hel"

import Html exposing (text)

main =
    let
        _ = Debug.log "left1" (String.left 3 "Hello")
        _ = Debug.log "right1" (String.right 3 "Hello")
        _ = Debug.log "dropLeft1" (String.dropLeft 3 "Hello")
        _ = Debug.log "dropRight1" (String.dropRight 2 "Hello")
    in
    text "done"
