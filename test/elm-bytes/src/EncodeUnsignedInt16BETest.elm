module EncodeUnsignedInt16BETest exposing (main)

{-| Test Bytes.Encode.unsignedInt16 with BE endianness.
-}

-- CHECK: EncodeUnsignedInt16BETest: 2

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.unsignedInt16 BE 0x1234)

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeUnsignedInt16BETest" result
    in
    text (String.fromInt result)
