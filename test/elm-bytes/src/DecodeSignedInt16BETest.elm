module DecodeSignedInt16BETest exposing (main)

{-| Test Bytes.Decode.signedInt16 BE decoding.
-}

-- CHECK: DecodeSignedInt16BETest: -1000

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.signedInt16 BE -1000)

        result =
            D.decode (D.signedInt16 BE) bytes
                |> Maybe.withDefault 0

        _ =
            Debug.log "DecodeSignedInt16BETest" result
    in
    text (String.fromInt result)
