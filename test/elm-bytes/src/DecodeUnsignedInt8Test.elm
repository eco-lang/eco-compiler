module DecodeUnsignedInt8Test exposing (main)

{-| Bytes.Decode.unsignedInt8 reads back a byte written by Bytes.Encode.unsignedInt8.

The byte 42 is encoded and decoded, and the logged result is 42. A failed
decode would log -1.

-}

-- CHECK: DecodeUnsignedInt8Test: 42

import Bytes exposing (Bytes)
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.unsignedInt8 42)

        result =
            D.decode D.unsignedInt8 bytes
                |> Maybe.withDefault -1

        _ =
            Debug.log "DecodeUnsignedInt8Test" result
    in
    text (String.fromInt result)
