module EncodeUnsignedInt32BETest exposing (main)

{-| Test Bytes.Encode.unsignedInt32 with BE endianness.
-}

-- CHECK: EncodeUnsignedInt32BETest: 4

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.unsignedInt32 BE 0x12345678)

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeUnsignedInt32BETest" result
    in
    text (String.fromInt result)
