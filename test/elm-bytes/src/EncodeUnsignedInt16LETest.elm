module EncodeUnsignedInt16LETest exposing (main)

{-| Test Bytes.Encode.unsignedInt16 with LE endianness.
-}

-- CHECK: EncodeUnsignedInt16LETest: 2

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.unsignedInt16 LE 0x1234)

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeUnsignedInt16LETest" result
    in
    text (String.fromInt result)
