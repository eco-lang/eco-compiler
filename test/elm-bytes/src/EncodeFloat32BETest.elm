module EncodeFloat32BETest exposing (main)

{-| `Bytes.Encode.float32` with big-endian order writes 4 bytes.

The test encodes `3.14159` and logs the width of the result.
-}

-- CHECK: EncodeFloat32BETest: 4

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.float32 BE 3.14159)

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeFloat32BETest" result
    in
    text (String.fromInt result)
