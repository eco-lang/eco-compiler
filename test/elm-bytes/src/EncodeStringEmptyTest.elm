module EncodeStringEmptyTest exposing (main)

{-| `Bytes.Encode.string ""` produces zero bytes.

The test logs the width of the encoded empty string.
-}

-- CHECK: EncodeStringEmptyTest: 0

import Bytes exposing (Bytes)
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.string "")

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeStringEmptyTest" result
    in
    text (String.fromInt result)
