module EncodeSignedInt16BETest exposing (main)

{-| `Bytes.Encode.signedInt16` with big-endian order writes 2 bytes for a negative value.

The test encodes `-1000` and logs the width of the result.
-}

-- CHECK: EncodeSignedInt16BETest: 2

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.signedInt16 BE -1000)

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeSignedInt16BETest" result
    in
    text (String.fromInt result)
