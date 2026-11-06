module EncodeCharTest exposing (main)

{-| A list of `Char` encodes to JSON as an array of their integer code points when each element
is encoded with `Json.Encode.int` of `Char.toCode`.

`Json.Encode` has no encoder for `Char`; here `[ 'a', 'b', 'c' ]` encodes to `[97,98,99]`.
-}

-- CHECK: char_codes: "[97,98,99]"


import Char
import Html exposing (text)
import Json.Encode as Encode


main =
    let
        chars : List Char
        chars =
            [ 'a', 'b', 'c' ]

        encoded =
            Encode.list (\c -> Encode.int (Char.toCode c)) chars

        _ =
            Debug.log "char_codes" (Encode.encode 0 encoded)
    in
    text "done"
