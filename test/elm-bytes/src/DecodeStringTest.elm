module DecodeStringTest exposing (main)

{-| Test Bytes.Decode.string decoding.
-}

-- CHECK: DecodeStringTest: "hello"

import Bytes exposing (Bytes)
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.string "hello")

        result =
            D.decode (D.string 5) bytes
                |> Maybe.withDefault "FAIL"

        _ =
            Debug.log "DecodeStringTest" result
    in
    text result
