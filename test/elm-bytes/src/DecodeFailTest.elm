module DecodeFailTest exposing (main)

{-| Test Bytes.Decode.fail always failing.
-}

-- CHECK: DecodeFailTest: "Nothing"

import Bytes exposing (Bytes)
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.unsignedInt8 0)

        decoder =
            D.fail

        result =
            D.decode decoder bytes

        output =
            case result of
                Nothing ->
                    "Nothing"

                Just _ ->
                    "FAIL"

        _ =
            Debug.log "DecodeFailTest" output
    in
    text output
