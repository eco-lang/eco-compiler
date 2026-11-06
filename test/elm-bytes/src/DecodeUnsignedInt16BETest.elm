module DecodeUnsignedInt16BETest exposing (main)

{-| Bytes.Decode.unsignedInt16 BE reads back a value written by
Bytes.Encode.unsignedInt16 BE.

The value 0x1234 is encoded and decoded big-endian, and the logged result is
4660, its decimal form. A failed decode would log -1.

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
