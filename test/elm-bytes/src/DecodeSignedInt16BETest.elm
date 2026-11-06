module DecodeSignedInt16BETest exposing (main)

{-| Bytes.Decode.signedInt16 BE reads back a negative value written by
Bytes.Encode.signedInt16 BE.

The value -1000 is encoded and decoded big-endian, and the logged result is
-1000. A failed decode would log 0.

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
