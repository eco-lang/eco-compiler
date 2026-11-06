module DecodeMap4Test exposing (main)

{-| Bytes.Decode.map4 combines four decoders that read consecutive bytes.

Four unsigned 8-bit values 1, 2, 3 and 4 are encoded, and `map4` reads them in
order and sums them, so the logged result is 10. A failed decode would log -1.

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
