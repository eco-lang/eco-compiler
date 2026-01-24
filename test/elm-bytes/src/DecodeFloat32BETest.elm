module DecodeFloat32BETest exposing (main)

{-| Test Bytes.Decode.float32 BE decoding.
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
