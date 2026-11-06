module EncodeUnsignedInt16BETest exposing (main)

{-| `Bytes.Encode.unsignedInt16` with big-endian order writes 2 bytes.

The test encodes `0x1234` and logs the width of the result.
-}

-- CHECK: EncodeUnsignedInt16BETest: 2

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.unsignedInt16 BE 0x1234)

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeUnsignedInt16BETest" result
    in
    text (String.fromInt result)
