module EncodeFloat64BETest exposing (main)

{-| `Bytes.Encode.float64` with big-endian order writes 8 bytes.

The test encodes `3.141592653589793` and logs the width of the result.
-}

-- CHECK: EncodeFloat64BETest: 8

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.float64 BE 3.141592653589793)

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeFloat64BETest" result
    in
    text (String.fromInt result)
