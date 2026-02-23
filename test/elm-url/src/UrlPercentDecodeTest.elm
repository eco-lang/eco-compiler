module UrlPercentDecodeTest exposing (main)

-- CHECK: decode1: Just "hello world"
-- CHECK: decode2: Just "a&b=c"

import Html exposing (text)
import Url

main =
    let
        _ = Debug.log "decode1" (Url.percentDecode "hello%20world")
        _ = Debug.log "decode2" (Url.percentDecode "a%26b%3Dc")
    in
    text "done"
