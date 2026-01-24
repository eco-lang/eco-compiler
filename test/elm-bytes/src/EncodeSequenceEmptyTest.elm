module EncodeSequenceEmptyTest exposing (main)

{-| Test Bytes.Encode.sequence with empty list.
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
