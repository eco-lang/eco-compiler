module UrlPercentEncodeTest exposing (main)

{-| `Url.percentEncode` escapes characters that have a meaning in a URL, but not every punctuation character.

A space, `&` and `=` become `%20`, `%26` and `%3D`. The characters
`( ) ! * ' ~` come back unchanged.

-}

-- CHECK: encode1: "hello%20world"
-- CHECK: encode2: "a%26b%3Dc"
-- CHECK: encode3: "a(b)!*'~"

import Html exposing (text)
import Url

main =
    let
        _ = Debug.log "encode1" (Url.percentEncode "hello world")
        _ = Debug.log "encode2" (Url.percentEncode "a&b=c")
        _ = Debug.log "encode3" (Url.percentEncode "a(b)!*'~")
    in
    text "done"
