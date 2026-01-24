module DecodeUnsignedInt16LETest exposing (main)

{-| Test Bytes.Decode.unsignedInt16 LE decoding.
-}

-- CHECK: DecodeUnsignedInt16LETest: 4660

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.unsignedInt16 LE 0x1234)

        result =
            D.decode (D.unsignedInt16 LE) bytes
                |> Maybe.withDefault -1

        _ =
            Debug.log "DecodeUnsignedInt16LETest" result
    in
    text (String.fromInt result)
