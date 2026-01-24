module EncodeSignedInt16BETest exposing (main)

{-| Test Bytes.Encode.signedInt16 with BE endianness.
-}

-- CHECK: EncodeSignedInt16BETest: 2

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.signedInt16 BE -1000)

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeSignedInt16BETest" result
    in
    text (String.fromInt result)
