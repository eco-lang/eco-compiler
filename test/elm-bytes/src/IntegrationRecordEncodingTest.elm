module IntegrationRecordEncodingTest exposing (main)

{-| Test encoding/decoding a record structure.
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
