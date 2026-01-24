module EncodeFloat32BETest exposing (main)

{-| Test Bytes.Encode.float32 with BE endianness.
-}

-- CHECK: EncodeFloat32BETest: 4

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.float32 BE 3.14159)

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeFloat32BETest" result
    in
    text (String.fromInt result)
