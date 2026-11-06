module JsonEncodeBigStringTest exposing (main)

{-| Checks that `Json.Encode.string` encodes a 5000-character string as a quoted JSON string.

The string is built with `String.repeat`, and the length of the encoded text is
printed: 5000 characters plus two quotes gives 5002.

-}

-- CHECK: JsonEncodeBigStringTest: 5002

import Html exposing (text)
import Json.Encode as E


main =
    let
        encoded =
            E.encode 0 (E.string (String.repeat 5000 "x"))

        _ =
            Debug.log "JsonEncodeBigStringTest" (String.length encoded)
    in
    text "ok"
