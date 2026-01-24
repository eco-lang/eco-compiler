module DecodeStringEmptyTest exposing (main)

{-| Test Bytes.Decode.string with empty string.
-}

-- CHECK: DecodeStringEmptyTest: ""

import Bytes exposing (Bytes)
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.string "")

        result =
            D.decode (D.string 0) bytes
                |> Maybe.withDefault "FAIL"

        _ =
            Debug.log "DecodeStringEmptyTest" result
    in
    text ("result: " ++ result)
