module EncodeSignedInt8Test exposing (main)

{-| Test Bytes.Encode.signedInt8 basic encoding.
-}

-- CHECK: EncodeSignedInt8Test: 1

import Bytes exposing (Bytes)
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.signedInt8 -42)

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeSignedInt8Test" result
    in
    text (String.fromInt result)
