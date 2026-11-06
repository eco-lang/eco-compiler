module EncodeUnsignedInt32LETest exposing (main)

{-| `Bytes.Encode.unsignedInt32` with little-endian order writes 4 bytes.

The test encodes `0x12345678` and logs the width of the result.
-}

-- CHECK: EncodeUnsignedInt32LETest: 4

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.unsignedInt32 LE 0x12345678)

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeUnsignedInt32LETest" result
    in
    text (String.fromInt result)
