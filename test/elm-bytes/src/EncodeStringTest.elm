module EncodeStringTest exposing (main)

{-| Test Bytes.Encode.string encoding.
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
