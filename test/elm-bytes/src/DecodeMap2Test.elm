module DecodeMap2Test exposing (main)

{-| Test Bytes.Decode.map2 combining two decoders.
-}

-- CHECK: DecodeMap2Test: 300

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode
                (E.sequence
                    [ E.unsignedInt8 100
                    , E.unsignedInt8 200
                    ]
                )

        decoder =
            D.map2 (+) D.unsignedInt8 D.unsignedInt8

        result =
            D.decode decoder bytes
                |> Maybe.withDefault -1

        _ =
            Debug.log "DecodeMap2Test" result
    in
    text (String.fromInt result)
