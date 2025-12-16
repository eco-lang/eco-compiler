module Simple exposing (main)

import Html exposing (text)

main =
    let
        rev = List.reverse [1,2,3]

        _ = Debug.log "main" "called"

        _ = Debug.log "List.reverse [1,2,3]" rev
    in
    text "Hello!"
