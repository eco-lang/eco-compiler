module DecodeInsufficientBytesTest exposing (main)

{-| Test decoding fails with insufficient bytes.
-}

-- CHECK: DecodeInsufficientBytesTest: True

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        -- Only 1 byte but trying to read 4
        bytes =
            E.encode (E.unsignedInt8 42)

        result =
            D.decode (D.unsignedInt32 BE) bytes

        isNothing =
            result == Nothing

        _ =
            Debug.log "DecodeInsufficientBytesTest" isNothing
    in
    text (if isNothing then "True" else "False")
