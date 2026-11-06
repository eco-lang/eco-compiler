module EncodeStringTest exposing (main)

{-| `Bytes.Encode.string` writes one byte per ASCII character.

The test encodes `"hello"` and logs the width of the result, 5.
-}

-- CHECK: EncodeStringTest: 5

import Bytes exposing (Bytes)
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.string "hello")

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeStringTest" result
    in
    text (String.fromInt result)
