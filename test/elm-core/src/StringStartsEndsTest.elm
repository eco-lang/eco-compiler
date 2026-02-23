module StringStartsEndsTest exposing (main)

-- CHECK: starts_yes: True
-- CHECK: starts_no: False
-- CHECK: ends_yes: True
-- CHECK: ends_no: False

import Html exposing (text)

main =
    let
        _ = Debug.log "starts_yes" (String.startsWith "He" "Hello")
        _ = Debug.log "starts_no" (String.startsWith "lo" "Hello")
        _ = Debug.log "ends_yes" (String.endsWith "lo" "Hello")
        _ = Debug.log "ends_no" (String.endsWith "He" "Hello")
    in
    text "done"
