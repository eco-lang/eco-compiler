module DecodeMapTest exposing (main)

{-| Bytes.Decode.map applies a function to the value a decoder produces.

A single unsigned byte 42 is decoded through `map (\x -> x * 2)`, so the logged
result is 84. A failed decode would log -1.

-}

-- CHECK: DecodeMapTest: 84

import Bytes exposing (Bytes)
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.unsignedInt8 42)

        decoder =
            D.map (\x -> x * 2) D.unsignedInt8

        result =
            D.decode decoder bytes
                |> Maybe.withDefault -1

        _ =
            Debug.log "DecodeMapTest" result
    in
    text (String.fromInt result)
