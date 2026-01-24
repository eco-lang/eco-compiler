module EncodeUnsignedInt8MaxTest exposing (main)

{-| Test encoding max value (255).
-}

-- CHECK: EncodeUnsignedInt8MaxTest: 1

import Bytes exposing (Bytes)
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.unsignedInt8 255)

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeUnsignedInt8MaxTest" result
    in
    text (String.fromInt result)
