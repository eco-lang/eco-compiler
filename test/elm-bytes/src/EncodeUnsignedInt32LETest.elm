module EncodeUnsignedInt32LETest exposing (main)

{-| Test Bytes.Encode.unsignedInt32 with LE endianness.
-}

-- CHECK: EncodeUnsignedInt32LETest: 4

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.unsignedInt32 LE 0x12345678)

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeUnsignedInt32LETest" result
    in
    text (String.fromInt result)
