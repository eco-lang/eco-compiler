module UrlPercentDecodeTest exposing (main)

{-| `Url.percentDecode` turns `%XX` escapes back into the characters they stand for.

`%20`, `%26` and `%3D` decode to a space, `&` and `=`. A `+` is left as a
literal `+`, not read as a space.

-}

-- CHECK: decode1: Just "hello world"
-- CHECK: decode2: Just "a&b=c"
-- CHECK: decode3: Just "a+b"

import Html exposing (text)
import Url

main =
    let
        _ = Debug.log "decode1" (Url.percentDecode "hello%20world")
        _ = Debug.log "decode2" (Url.percentDecode "a%26b%3Dc")
        _ = Debug.log "decode3" (Url.percentDecode "a+b")
    in
    text "done"
