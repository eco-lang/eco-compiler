module DecodeEmptyBytesTest exposing (main)

{-| Test decoding from empty bytes.
-}

-- CHECK: DecodeEmptyBytesTest: True

import Bytes exposing (Bytes)
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.sequence [])

        result =
            D.decode D.unsignedInt8 bytes

        isNothing =
            result == Nothing

        _ =
            Debug.log "DecodeEmptyBytesTest" isNothing
    in
    text (if isNothing then "True" else "False")
