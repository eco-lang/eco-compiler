module DecodeMap4Test exposing (main)

{-| Test Bytes.Decode.map4 combining four decoders.
-}

-- CHECK: DecodeMap4Test: 10

import Bytes exposing (Bytes)
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode
                (E.sequence
                    [ E.unsignedInt8 1
                    , E.unsignedInt8 2
                    , E.unsignedInt8 3
                    , E.unsignedInt8 4
                    ]
                )

        decoder =
            D.map4 (\a b c d -> a + b + c + d)
                D.unsignedInt8
                D.unsignedInt8
                D.unsignedInt8
                D.unsignedInt8

        result =
            D.decode decoder bytes
                |> Maybe.withDefault -1

        _ =
            Debug.log "DecodeMap4Test" result
    in
    text (String.fromInt result)
