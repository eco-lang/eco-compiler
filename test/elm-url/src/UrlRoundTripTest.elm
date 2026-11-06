module UrlRoundTripTest exposing (main)

{-| `Url.percentDecode` undoes `Url.percentEncode`, giving back `Just` the original string.

The two strings round-tripped contain a space and the URL delimiters
`/ ? = &`.

-}

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
