module DecodeStringEmptyTest exposing (main)

{-| Bytes.Decode.string 0 decodes the empty string.

The empty string is encoded, which produces no bytes, and `string 0` reads it
back. `Debug.log` shows the result as `""`; a failed decode would log `"FAIL"`.

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
