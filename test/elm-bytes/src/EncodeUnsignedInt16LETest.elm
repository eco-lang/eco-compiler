module EncodeUnsignedInt16LETest exposing (main)

{-| `Bytes.Encode.unsignedInt16` with little-endian order writes 2 bytes.

The test encodes `0x1234` and logs the width of the result.
-}

-- CHECK: EncodeUnsignedInt16LETest: 2

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.unsignedInt16 LE 0x1234)

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeUnsignedInt16LETest" result
    in
    text (String.fromInt result)
