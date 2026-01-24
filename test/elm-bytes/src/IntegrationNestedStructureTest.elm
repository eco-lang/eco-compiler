module IntegrationNestedStructureTest exposing (main)

{-| Test encoding/decoding nested structures.
-}

-- CHECK: IntegrationNestedStructureTest: True

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


type alias Inner =
    { x : Int
    , y : Int
    }


type alias Outer =
    { id : Int
    , inner : Inner
    }


encodeInner : Inner -> E.Encoder
encodeInner i =
    E.sequence
        [ E.unsignedInt16 BE i.x
        , E.unsignedInt16 BE i.y
        ]


encodeOuter : Outer -> E.Encoder
encodeOuter o =
    E.sequence
        [ E.unsignedInt8 o.id
        , encodeInner o.inner
        ]


decodeInner : D.Decoder Inner
decodeInner =
    D.map2 Inner
        (D.unsignedInt16 BE)
        (D.unsignedInt16 BE)


decodeOuter : D.Decoder Outer
decodeOuter =
    D.map2 Outer
        D.unsignedInt8
        decodeInner


main =
    let
        original =
            { id = 42
            , inner = { x = 100, y = 200 }
            }

        encoded =
            E.encode (encodeOuter original)

        decoded =
            D.decode decodeOuter encoded

        result =
            case decoded of
                Just o ->
                    (o.id == 42)
                        && (o.inner.x == 100)
                        && (o.inner.y == 200)

                Nothing ->
                    False

        _ =
            Debug.log "IntegrationNestedStructureTest" result
    in
    text (if result then "True" else "False")
