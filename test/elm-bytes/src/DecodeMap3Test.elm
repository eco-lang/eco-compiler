module DecodeMap3Test exposing (main)

{-| Test Bytes.Decode.map3 combining three decoders.
-}

-- CHECK: DecodeMap3Test: 600

import Bytes exposing (Bytes)
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
                    , E.unsignedInt8 300
                    ]
                )

        decoder =
            D.map3 (\a b c -> a + b + c) D.unsignedInt8 D.unsignedInt8 D.unsignedInt8

        result =
            D.decode decoder bytes
                |> Maybe.withDefault -1

        _ =
            Debug.log "DecodeMap3Test" result
    in
    text (String.fromInt result)
