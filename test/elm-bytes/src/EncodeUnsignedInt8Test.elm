module EncodeUnsignedInt8Test exposing (main)

{-| Test Bytes.Encode.unsignedInt8 basic encoding.
-}

-- CHECK: EncodeUnsignedInt8Test: 1

import Bytes exposing (Bytes)
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.unsignedInt8 42)

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeUnsignedInt8Test" result
    in
    text (String.fromInt result)
