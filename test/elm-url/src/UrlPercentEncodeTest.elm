module UrlPercentEncodeTest exposing (main)

-- CHECK: encode1: "hello%20world"
-- CHECK: encode2: "a%26b%3Dc"

import Html exposing (text)
import Url

main =
    let
        _ = Debug.log "encode1" (Url.percentEncode "hello world")
        _ = Debug.log "encode2" (Url.percentEncode "a&b=c")
    in
    text "done"
