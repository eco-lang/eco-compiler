module UrlRoundTripTest exposing (main)

-- CHECK: roundtrip1: Just "hello world"
-- CHECK: roundtrip2: Just "a/b?c=d&e=f"

import Html exposing (text)
import Url

main =
    let
        _ = Debug.log "roundtrip1" (Url.percentDecode (Url.percentEncode "hello world"))
        _ = Debug.log "roundtrip2" (Url.percentDecode (Url.percentEncode "a/b?c=d&e=f"))
    in
    text "done"
