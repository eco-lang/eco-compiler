module Utils.Bytes.Encode exposing
    ( assocListDict
    , bool
    , everySet
    , float
    , int
    , jsonPair
    , list
    , maybe
    , nonempty
    , oneOrMore
    , result
    , string
    , unit
    )

import Bytes
import Bytes.Encode as BE
import Compiler.Data.NonEmptyList as NE
import Compiler.Data.OneOrMore exposing (OneOrMore(..))
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)


endian : Bytes.Endianness
endian =
    Bytes.BE


unit : () -> BE.Encoder
unit () =
    BE.unsignedInt8 0


int : Int -> BE.Encoder
int =
    toFloat >> BE.float64 endian


float : Float -> BE.Encoder
float =
    BE.float64 endian


string : String -> BE.Encoder
string str =
    BE.sequence
        [ BE.unsignedInt32 endian (BE.getStringWidth str)
        , BE.string str
        ]


bool : Bool -> BE.Encoder
bool value =
    BE.unsignedInt8
        (if value then
            1

         else
            0
        )


list : (a -> BE.Encoder) -> List a -> BE.Encoder
list encoder aList =
    BE.sequence
        (BE.unsignedInt32 endian (List.length aList)
            :: List.map encoder aList
        )


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


nonempty : (a -> BE.Encoder) -> NE.Nonempty a -> BE.Encoder
nonempty encoder (NE.Nonempty x xs) =
    list encoder (x :: xs)


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


assocListDict : (k -> k -> Order) -> (k -> BE.Encoder) -> (v -> BE.Encoder) -> Dict c k v -> BE.Encoder
assocListDict keyComparison keyEncoder valueEncoder =
    Dict.toList keyComparison >> List.reverse >> list (jsonPair keyEncoder valueEncoder)


jsonPair : (a -> BE.Encoder) -> (b -> BE.Encoder) -> ( a, b ) -> BE.Encoder
jsonPair encoderA encoderB ( a, b ) =
    BE.sequence
        [ encoderA a
        , encoderB b
        ]


everySet : (a -> a -> Order) -> (a -> BE.Encoder) -> EverySet c a -> BE.Encoder
everySet keyComparison encoder =
    EverySet.toList keyComparison >> List.reverse >> list encoder


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
