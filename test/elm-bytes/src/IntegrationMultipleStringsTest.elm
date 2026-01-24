module IntegrationMultipleStringsTest exposing (main)

{-| Test encoding/decoding multiple length-prefixed strings.
-}

-- CHECK: IntegrationMultipleStringsTest: True

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


encodeStringWithLen : String -> E.Encoder
encodeStringWithLen s =
    E.sequence
        [ E.unsignedInt8 (String.length s)
        , E.string s
        ]


decodeStringWithLen : D.Decoder String
decodeStringWithLen =
    D.unsignedInt8 |> D.andThen D.string


main =
    let
        s1 =
            "Hi"

        s2 =
            "World"

        s3 =
            "!"

        encoded =
            E.encode
                (E.sequence
                    [ encodeStringWithLen s1
                    , encodeStringWithLen s2
                    , encodeStringWithLen s3
                    ]
                )

        decoder =
            D.map3 (\a b c -> [ a, b, c ])
                decodeStringWithLen
                decodeStringWithLen
                decodeStringWithLen

        decoded =
            D.decode decoder encoded
                |> Maybe.withDefault []

        result =
            decoded == [ s1, s2, s3 ]

        _ =
            Debug.log "IntegrationMultipleStringsTest" result
    in
    text (if result then "True" else "False")
