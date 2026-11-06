module DecodeFloat32BETest exposing (main)

{-| `Bytes.Decode.float32 BE` reads back a 32-bit big-endian float written by `Bytes.Encode.float32 BE`.

The value `3.14159` does not survive 32-bit precision exactly, so the test rounds the decoded value to two decimal places and expects `3.14`.
-}

-- CHECK: DecodeFloat32BETest: 3.14

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.float32 BE 3.14159)

        result =
            D.decode (D.float32 BE) bytes
                |> Maybe.withDefault 0.0

        -- Float32 has limited precision
        rounded =
            toFloat (round (result * 100)) / 100

        _ =
            Debug.log "DecodeFloat32BETest" rounded
    in
    text (String.fromFloat rounded)
