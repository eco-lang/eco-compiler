module RoundtripMixedTypesTest exposing (main)

{-| Roundtrip test with mixed types in sequence.
-}

-- CHECK: RoundtripMixedTypesTest: True

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


type alias Record =
    { a : Int
    , b : Int
    , c : Float
    }


main =
    let
        original =
            { a = 42, b = 1000, c = 3.14 }

        encoded =
            E.encode
                (E.sequence
                    [ E.unsignedInt8 original.a
                    , E.unsignedInt16 BE original.b
                    , E.float64 BE original.c
                    ]
                )

        decoder =
            D.map3 Record
                D.unsignedInt8
                (D.unsignedInt16 BE)
                (D.float64 BE)

        decoded =
            D.decode decoder encoded

        result =
            case decoded of
                Just r ->
                    r.a == original.a && r.b == original.b && r.c == original.c

                Nothing ->
                    False

        _ =
            Debug.log "RoundtripMixedTypesTest" result
    in
    text (if result then "True" else "False")
