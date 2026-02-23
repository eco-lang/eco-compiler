module HttpHeaderTest exposing (main)

-- CHECK: header_created: True

import Html exposing (text)
import Http

main =
    let
        h = Http.header "Content-Type" "application/json"
        _ = Debug.log "header_created" True
    in
    text "done"
