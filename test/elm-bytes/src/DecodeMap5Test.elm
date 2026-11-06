module DecodeMap5Test exposing (main)

{-| Bytes.Decode.map5 combines five decoders that read consecutive bytes.

Five unsigned 8-bit values 1 to 5 are encoded, and `map5` reads them in order and
sums them, so the logged result is 15. A failed decode would log -1.

-}

-- CHECK: DecodeMap5Test: 15

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
                    , E.unsignedInt8 5
                    ]
                )

        decoder =
            D.map5 (\a b c d e -> a + b + c + d + e)
                D.unsignedInt8
                D.unsignedInt8
                D.unsignedInt8
                D.unsignedInt8
                D.unsignedInt8

        result =
            D.decode decoder bytes
                |> Maybe.withDefault -1

        _ =
            Debug.log "DecodeMap5Test" result
    in
    text (String.fromInt result)
