module DecodeMap5Test exposing (main)

{-| Test Bytes.Decode.map5 combining five decoders.
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
