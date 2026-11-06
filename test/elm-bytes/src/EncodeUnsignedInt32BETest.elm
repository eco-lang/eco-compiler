module EncodeUnsignedInt32BETest exposing (main)

{-| `Bytes.Encode.unsignedInt32` with big-endian order writes 4 bytes.

The test encodes `0x12345678` and logs the width of the result.
-}

-- CHECK: EncodeUnsignedInt32BETest: 4

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.unsignedInt32 BE 0x12345678)

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeUnsignedInt32BETest" result
    in
    text (String.fromInt result)
