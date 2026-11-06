module EncodeUnsignedInt8Test exposing (main)

{-| `Bytes.Encode.unsignedInt8` writes 1 byte.

The test encodes `42` and logs the width of the result.
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
