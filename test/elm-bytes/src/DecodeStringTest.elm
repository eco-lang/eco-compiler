module DecodeStringTest exposing (main)

{-| Bytes.Decode.string reads back a string written by Bytes.Encode.string.

`"hello"` is encoded and decoded with `string 5`, and the logged result is
`"hello"`. A failed decode would log `"FAIL"`.

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
