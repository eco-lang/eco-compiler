module EncodeLargeSequenceTest exposing (main)

{-| `Bytes.Encode.sequence` of 100 `unsignedInt8` encoders produces 100 bytes.

The test encodes a list of 100 zero bytes and logs the width of the result.
-}

-- CHECK: EncodeLargeSequenceTest: 100

import Bytes exposing (Bytes)
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        encoders =
            List.repeat 100 (E.unsignedInt8 0)

        bytes =
            E.encode (E.sequence encoders)

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeLargeSequenceTest" result
    in
    text (String.fromInt result)
