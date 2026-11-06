module DecodeSignedInt8Test exposing (main)

{-| Bytes.Decode.signedInt8 reads back a negative value written by
Bytes.Encode.signedInt8.

The value -42 is encoded as one byte and decoded, and the logged result is -42.
A failed decode would log 0.

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
