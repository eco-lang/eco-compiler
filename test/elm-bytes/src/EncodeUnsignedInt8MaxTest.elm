module EncodeUnsignedInt8MaxTest exposing (main)

{-| `Bytes.Encode.unsignedInt8` writes 1 byte for its largest value, 255.

The test logs the width of the result.
-}

-- CHECK: EncodeUnsignedInt8MaxTest: 1

import Bytes exposing (Bytes)
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.unsignedInt8 255)

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeUnsignedInt8MaxTest" result
    in
    text (String.fromInt result)
