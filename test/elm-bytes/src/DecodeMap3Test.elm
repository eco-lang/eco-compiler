module DecodeMap3Test exposing (main)

{-| `Bytes.Decode.map3` combines three decoders in order, adding three unsigned bytes.

The third byte is written with `Bytes.Encode.unsignedInt8 300`. Only the low eight bits of an out-of-range value are kept, so it is stored as 44, and the sum is 100 + 200 + 44 = 344.
-}

-- CHECK: DecodeMap3Test: 344

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
