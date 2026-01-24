module DecodeSignedInt32BETest exposing (main)

{-| Test Bytes.Decode.signedInt32 BE decoding.
-}

-- CHECK: DecodeSignedInt32BETest: -100000

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.signedInt32 BE -100000)

        result =
            D.decode (D.signedInt32 BE) bytes
                |> Maybe.withDefault 0

        _ =
            Debug.log "DecodeSignedInt32BETest" result
    in
    text (String.fromInt result)
