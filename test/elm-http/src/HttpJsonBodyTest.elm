module HttpJsonBodyTest exposing (main)

-- CHECK: body_created: True

import Html exposing (text)
import Http
import Json.Encode as Encode

main =
    let
        body = Http.jsonBody (Encode.object [("key", Encode.string "value")])
        _ = Debug.log "body_created" True
    in
    text "done"
