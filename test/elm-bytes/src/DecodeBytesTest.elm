module DecodeBytesTest exposing (main)

{-| Test Bytes.Decode.bytes slicing bytes.
-}

-- CHECK: DecodeBytesTest: 3

import Bytes exposing (Bytes, Endianness(..))
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
            D.bytes 3

        result =
            D.decode decoder bytes
                |> Maybe.map Bytes.width
                |> Maybe.withDefault -1

        _ =
            Debug.log "DecodeBytesTest" result
    in
    text (String.fromInt result)
