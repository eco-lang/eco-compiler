module EncodeUnsignedInt8ZeroTest exposing (main)

{-| Test encoding zero value.
-}

-- CHECK: EncodeUnsignedInt8ZeroTest: 1

import Bytes exposing (Bytes)
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.unsignedInt8 0)

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeUnsignedInt8ZeroTest" result
    in
    text (String.fromInt result)
