module DecodeSucceedTest exposing (main)

{-| Test Bytes.Decode.succeed always succeeding.
-}

-- CHECK: DecodeSucceedTest: 42

import Bytes exposing (Bytes)
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.unsignedInt8 0)

        decoder =
            D.succeed 42

        result =
            D.decode decoder bytes
                |> Maybe.withDefault -1

        _ =
            Debug.log "DecodeSucceedTest" result
    in
    text (String.fromInt result)
