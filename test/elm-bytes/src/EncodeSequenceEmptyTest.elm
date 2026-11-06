module EncodeSequenceEmptyTest exposing (main)

{-| `Bytes.Encode.sequence []` produces zero bytes.

The test logs the width of the encoded empty sequence.
-}

-- CHECK: EncodeSequenceEmptyTest: 0

import Bytes exposing (Bytes)
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.sequence [])

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeSequenceEmptyTest" result
    in
    text (String.fromInt result)
