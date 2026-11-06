module EncodeSignedInt32BETest exposing (main)

{-| `Bytes.Encode.signedInt32` with big-endian order writes 4 bytes for a negative value.

The test encodes `-100000` and logs the width of the result.
-}

-- CHECK: EncodeSignedInt32BETest: 4

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.signedInt32 BE -100000)

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeSignedInt32BETest" result
    in
    text (String.fromInt result)
