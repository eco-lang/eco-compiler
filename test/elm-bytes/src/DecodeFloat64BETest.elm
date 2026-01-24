module DecodeFloat64BETest exposing (main)

{-| Test Bytes.Decode.float64 BE decoding.
-}

-- CHECK: DecodeFloat64BETest: 3.141592653589793

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.float64 BE 3.141592653589793)

        result =
            D.decode (D.float64 BE) bytes
                |> Maybe.withDefault 0.0

        _ =
            Debug.log "DecodeFloat64BETest" result
    in
    text (String.fromFloat result)
