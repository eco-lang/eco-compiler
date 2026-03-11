module Utils.Bytes.Encode exposing
    ( unit, bool, int, float, string
    , maybe, list, nonempty, result, oneOrMore
    , jsonPair, assocListDict, stdDict, everySet
    )

{-| Binary encoding utilities for Elm values, providing consistent serialization for the compiler's
data structures. All encoders use big-endian byte order and include length prefixes for variable-length
data to enable reliable deserialization.


# Primitive Encoders

@docs unit, bool, int, float, string


# Container Encoders

@docs maybe, list, nonempty, result, oneOrMore


# Structured Data Encoders

@docs jsonPair, assocListDict, stdDict, everySet

-}

import Bytes
import Bytes.Encode as BE
import Compiler.Data.NonEmptyList as NE
import Compiler.Data.OneOrMore exposing (OneOrMore(..))
import Data.Map as EveryDict
import Data.Set as EverySet exposing (EverySet)
import Dict


endian : Bytes.Endianness
endian =
    Bytes.BE


{-| Encodes a unit value as a single zero byte.
-}
unit : () -> BE.Encoder
unit () =
    BE.unsignedInt8 0


{-| Encodes an integer as a 64-bit float in big-endian byte order.
-}
int : Int -> BE.Encoder
int =
    toFloat >> BE.float64 endian


{-| Encodes a 64-bit floating point number in big-endian byte order.
-}
float : Float -> BE.Encoder
float =
    BE.float64 endian


{-| Encodes a UTF-8 string with a length prefix.
-}
string : String -> BE.Encoder
string str =
    BE.sequence
        [ BE.unsignedInt32 endian (BE.getStringWidth str)
        , BE.string str
        ]


{-| Encodes a boolean value as a single byte, where true is 1 and false is 0.
-}
bool : Bool -> BE.Encoder
bool value =
    BE.unsignedInt8
        (if value then
            1

         else
            0
        )


{-| Encodes a list with a length prefix followed by encoded elements.
-}
list : (a -> BE.Encoder) -> List a -> BE.Encoder
list encoder aList =
    BE.sequence
        (BE.unsignedInt32 endian (List.length aList)
            :: List.map encoder aList
        )


{-| Encodes a Maybe value with a leading byte indicating presence (1) or absence (0).
-}
maybe : (a -> BE.Encoder) -> Maybe a -> BE.Encoder
maybe encoder maybeValue =
    case maybeValue of
        Just value ->
            BE.sequence
                [ BE.unsignedInt8 1
                , encoder value
                ]

        Nothing ->
            BE.unsignedInt8 0


{-| Encodes a non-empty list as a regular list.
-}
nonempty : (a -> BE.Encoder) -> NE.Nonempty a -> BE.Encoder
nonempty encoder (NE.Nonempty x xs) =
    list encoder (x :: xs)


{-| Encodes a Result value with a leading byte indicating Ok (0) or Err (1).
-}
result : (x -> BE.Encoder) -> (a -> BE.Encoder) -> Result x a -> BE.Encoder
result errEncoder successEncoder resultValue =
    case resultValue of
        Ok value ->
            BE.sequence
                [ BE.unsignedInt8 0
                , successEncoder value
                ]

        Err err ->
            BE.sequence
                [ BE.unsignedInt8 1
                , errEncoder err
                ]


{-| Encodes a dictionary as a list of key-value pairs.
-}
assocListDict : (k -> k -> Order) -> (k -> BE.Encoder) -> (v -> BE.Encoder) -> EveryDict.Dict c k v -> BE.Encoder
assocListDict keyComparison keyEncoder valueEncoder =
    EveryDict.toList keyComparison >> List.reverse >> list (jsonPair keyEncoder valueEncoder)


{-| Encodes a stdlib Dict as a list of key-value pairs.
-}
stdDict : (comparable -> BE.Encoder) -> (v -> BE.Encoder) -> Dict.Dict comparable v -> BE.Encoder
stdDict keyEncoder valueEncoder =
    Dict.toList >> list (jsonPair keyEncoder valueEncoder)


{-| Encodes a pair of values as a tuple.
-}
jsonPair : (a -> BE.Encoder) -> (b -> BE.Encoder) -> ( a, b ) -> BE.Encoder
jsonPair encoderA encoderB ( a, b ) =
    BE.sequence
        [ encoderA a
        , encoderB b
        ]


{-| Encodes a set as a list of elements.
-}
everySet : (a -> a -> Order) -> (a -> BE.Encoder) -> EverySet c a -> BE.Encoder
everySet keyComparison encoder =
    EverySet.toList keyComparison >> List.reverse >> list encoder


{-| Encodes a binary tree structure with at least one element.
-}
oneOrMore : (a -> BE.Encoder) -> OneOrMore a -> BE.Encoder
oneOrMore encoder oneOrMore_ =
    case oneOrMore_ of
        One value ->
            BE.sequence
                [ BE.unsignedInt8 0
                , encoder value
                ]

        More left right ->
            BE.sequence
                [ BE.unsignedInt8 1
                , oneOrMore encoder left
                , oneOrMore encoder right
                ]
