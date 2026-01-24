module DecodeUnsignedInt16BETest exposing (main)

{-| Test Bytes.Decode.unsignedInt16 BE decoding.
-}

-- CHECK: DecodeUnsignedInt16BETest: 4660

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.unsignedInt16 BE 0x1234)

        result =
            D.decode (D.unsignedInt16 BE) bytes
                |> Maybe.withDefault -1

        _ =
            Debug.log "DecodeUnsignedInt16BETest" result
    in
    text (String.fromInt result)
