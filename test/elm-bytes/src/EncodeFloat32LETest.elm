module EncodeFloat32LETest exposing (main)

{-| Test Bytes.Encode.float32 with LE endianness.
-}

-- CHECK: EncodeFloat32LETest: 4

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.float32 LE 3.14159)

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeFloat32LETest" result
    in
    text (String.fromInt result)
