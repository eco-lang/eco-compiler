module DecodeUnsignedInt32BETest exposing (main)

{-| Test Bytes.Decode.unsignedInt32 BE decoding.
-}

-- CHECK: DecodeUnsignedInt32BETest: 305419896

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.unsignedInt32 BE 0x12345678)

        result =
            D.decode (D.unsignedInt32 BE) bytes
                |> Maybe.withDefault -1

        _ =
            Debug.log "DecodeUnsignedInt32BETest" result
    in
    text (String.fromInt result)
