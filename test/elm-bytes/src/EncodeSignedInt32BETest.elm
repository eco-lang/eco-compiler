module EncodeSignedInt32BETest exposing (main)

{-| Test Bytes.Encode.signedInt32 with BE endianness.
-}

-- CHECK: EncodeSignedInt32BETest: 4

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.signedInt32 BE -100000)

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeSignedInt32BETest" result
    in
    text (String.fromInt result)
