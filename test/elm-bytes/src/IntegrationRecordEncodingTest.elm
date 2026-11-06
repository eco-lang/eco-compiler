module IntegrationRecordEncodingTest exposing (main)

{-| A record of two bytes and a 32-bit float round-trips through elm/bytes, decoded with `Bytes.Decode.map3`.

`age` and `nameLen` are encoded as `unsignedInt8` and `height` as a big-endian
`float32`. The record `{ age = 30, height = 1.75, nameLen = 5 }` is encoded and
decoded; the program logs `True` only if the integers are equal and `height` is
within 0.01 of 1.75.
-}

-- CHECK: IntegrationRecordEncodingTest: True

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


type alias Person =
    { age : Int
    , height : Float
    , nameLen : Int
    }


encodePerson : Person -> E.Encoder
encodePerson p =
    E.sequence
        [ E.unsignedInt8 p.age
        , E.float32 BE p.height
        , E.unsignedInt8 p.nameLen
        ]


decodePerson : D.Decoder Person
decodePerson =
    D.map3 Person
        D.unsignedInt8
        (D.float32 BE)
        D.unsignedInt8


main =
    let
        original =
            { age = 30, height = 1.75, nameLen = 5 }

        encoded =
            E.encode (encodePerson original)

        decoded =
            D.decode decodePerson encoded

        result =
            case decoded of
                Just p ->
                    (p.age == 30)
                        && (abs (p.height - 1.75) < 0.01)
                        && (p.nameLen == 5)

                Nothing ->
                    False

        _ =
            Debug.log "IntegrationRecordEncodingTest" result
    in
    text (if result then "True" else "False")
