module DecodeUnsignedInt32BETest exposing (main)

{-| Bytes.Decode.unsignedInt32 BE reads back a value written by
Bytes.Encode.unsignedInt32 BE.

The value 0x12345678 is encoded and decoded big-endian, and the logged result is
305419896, its decimal form. A failed decode would log -1.

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
