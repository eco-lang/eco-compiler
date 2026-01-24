module DecodeSignedInt8Test exposing (main)

{-| Test Bytes.Decode.signedInt8 decoding.
-}

-- CHECK: DecodeSignedInt8Test: -42

import Bytes exposing (Bytes)
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.signedInt8 -42)

        result =
            D.decode D.signedInt8 bytes
                |> Maybe.withDefault 0

        _ =
            Debug.log "DecodeSignedInt8Test" result
    in
    text (String.fromInt result)
