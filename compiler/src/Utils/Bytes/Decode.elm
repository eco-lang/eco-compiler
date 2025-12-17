module Utils.Bytes.Decode exposing
    ( unit, bool, int, float, string
    , maybe, list, nonempty, result, oneOrMore
    , jsonPair, assocListDict, everySet
    , map6, map7, map8
    , lazy
    )

{-| Binary decoding utilities for Elm values, providing the inverse operations for Utils.Bytes.Encode.
All decoders expect big-endian byte order and handle length-prefixed data structures. These decoders
enable reliable deserialization of the compiler's binary cache files and inter-process communication.


# Primitive Decoders

@docs unit, bool, int, float, string


# Container Decoders

@docs maybe, list, nonempty, result, oneOrMore


# Structured Data Decoders

@docs jsonPair, assocListDict, everySet


# Extended Mapping Functions

@docs map6, map7, map8


# Utility Functions

@docs lazy

-}

import Bytes
import Bytes.Decode as BD
import Compiler.Data.NonEmptyList as NE
import Compiler.Data.OneOrMore as OneOrMore exposing (OneOrMore)
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)


endian : Bytes.Endianness
endian =
    Bytes.BE


string : BD.Decoder String
string =
    BD.unsignedInt32 endian
        |> BD.andThen BD.string


unit : BD.Decoder ()
unit =
    BD.unsignedInt8
        |> BD.andThen
            (\idx ->
                case idx of
                    0 ->
                        BD.succeed ()

                    _ ->
                        BD.fail
            )


int : BD.Decoder Int
int =
    BD.float64 endian |> BD.map round


float : BD.Decoder Float
float =
    BD.float64 endian


bool : BD.Decoder Bool
bool =
    BD.map ((==) 1) BD.unsignedInt8


list : BD.Decoder a -> BD.Decoder (List a)
list decoder =
    BD.unsignedInt32 endian
        |> BD.andThen (\len -> BD.loop ( len, [] ) (listStep decoder))


listStep : BD.Decoder a -> ( Int, List a ) -> BD.Decoder (BD.Step ( Int, List a ) (List a))
listStep decoder ( n, xs ) =
    if n <= 0 then
        BD.succeed (BD.Done (List.reverse xs))

    else
        BD.map (\x -> BD.Loop ( n - 1, x :: xs )) decoder


maybe : BD.Decoder a -> BD.Decoder (Maybe a)
maybe decoder =
    BD.unsignedInt8
        |> BD.andThen
            (\n ->
                if n == 0 then
                    BD.succeed Nothing

                else
                    BD.map Just decoder
            )


result : BD.Decoder x -> BD.Decoder a -> BD.Decoder (Result x a)
result errDecoder successDecoder =
    BD.unsignedInt8
        |> BD.andThen
            (\idx ->
                case idx of
                    0 ->
                        BD.map Ok successDecoder

                    1 ->
                        BD.map Err errDecoder

                    _ ->
                        BD.fail
            )


map6 : (a -> b -> c -> d -> e -> f -> result) -> BD.Decoder a -> BD.Decoder b -> BD.Decoder c -> BD.Decoder d -> BD.Decoder e -> BD.Decoder f -> BD.Decoder result
map6 func decodeA decodeB decodeC decodeD decodeE decodeF =
    BD.map5 (\a b c d ( e, f ) -> func a b c d e f)
        decodeA
        decodeB
        decodeC
        decodeD
        (BD.map2 Tuple.pair
            decodeE
            decodeF
        )


map7 : (a -> b -> c -> d -> e -> f -> g -> result) -> BD.Decoder a -> BD.Decoder b -> BD.Decoder c -> BD.Decoder d -> BD.Decoder e -> BD.Decoder f -> BD.Decoder g -> BD.Decoder result
map7 func decodeA decodeB decodeC decodeD decodeE decodeF decodeG =
    map6 (\a b c d e ( f, g ) -> func a b c d e f g)
        decodeA
        decodeB
        decodeC
        decodeD
        decodeE
        (BD.map2 Tuple.pair
            decodeF
            decodeG
        )


map8 : (a -> b -> c -> d -> e -> f -> g -> h -> result) -> BD.Decoder a -> BD.Decoder b -> BD.Decoder c -> BD.Decoder d -> BD.Decoder e -> BD.Decoder f -> BD.Decoder g -> BD.Decoder h -> BD.Decoder result
map8 func decodeA decodeB decodeC decodeD decodeE decodeF decodeG decodeH =
    map7 (\a b c d e f ( g, h ) -> func a b c d e f g h)
        decodeA
        decodeB
        decodeC
        decodeD
        decodeE
        decodeF
        (BD.map2 Tuple.pair
            decodeG
            decodeH
        )


assocListDict : (k -> comparable) -> BD.Decoder k -> BD.Decoder v -> BD.Decoder (Dict comparable k v)
assocListDict toComparable keyDecoder valueDecoder =
    list (jsonPair keyDecoder valueDecoder)
        |> BD.map (Dict.fromList toComparable)


jsonPair : BD.Decoder a -> BD.Decoder b -> BD.Decoder ( a, b )
jsonPair =
    BD.map2 Tuple.pair


everySet : (a -> comparable) -> BD.Decoder a -> BD.Decoder (EverySet comparable a)
everySet toComparable decoder =
    list decoder
        |> BD.map (EverySet.fromList toComparable)


nonempty : BD.Decoder a -> BD.Decoder (NE.Nonempty a)
nonempty decoder =
    list decoder
        |> BD.andThen
            (\values ->
                case values of
                    x :: xs ->
                        BD.succeed (NE.Nonempty x xs)

                    [] ->
                        BD.fail
            )


oneOrMore : BD.Decoder a -> BD.Decoder (OneOrMore a)
oneOrMore decoder =
    BD.unsignedInt8
        |> BD.andThen
            (\idx ->
                case idx of
                    0 ->
                        BD.map OneOrMore.one decoder

                    1 ->
                        BD.map2 OneOrMore.more
                            (lazy (\_ -> oneOrMore decoder))
                            (lazy (\_ -> oneOrMore decoder))

                    _ ->
                        BD.fail
            )


lazy : (() -> BD.Decoder a) -> BD.Decoder a
lazy f =
    BD.succeed () |> BD.andThen f
