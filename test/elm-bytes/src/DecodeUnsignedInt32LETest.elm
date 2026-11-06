module DecodeUnsignedInt32LETest exposing (main)

{-| Bytes.Decode.unsignedInt32 LE reads back a value written by
Bytes.Encode.unsignedInt32 LE.

The value 0x12345678 is encoded and decoded little-endian, and the logged result
is 305419896, its decimal form. A failed decode would log -1.

-}

-- CHECK: DecodeUnsignedInt32LETest: 305419896

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.unsignedInt32 LE 0x12345678)

        result =
            D.decode (D.unsignedInt32 LE) bytes
                |> Maybe.withDefault -1

        _ =
            Debug.log "DecodeUnsignedInt32LETest" result
    in
    text (String.fromInt result)
