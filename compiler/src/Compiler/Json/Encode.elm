module Compiler.Json.Encode exposing
    ( Value(..)
    , string, name, chars, bool, int, number, null
    , array, list, object, dict, assocListDict, everySet
    , maybe, result, nonempty, oneOrMore, jsonPair
    , encodeUgly
    , write, writeUgly
    , toJsonValue
    )

{-| JSON encoding utilities for the Elm compiler.

This module provides a custom JSON value representation and encoding functions
tailored for compiler data structures. It supports encoding compiler-specific types
like associative-list-backed dictionaries, EverySet, NonEmptyList, and OneOrMore,
as well as pretty-printed and compact JSON output.


# Value Type

@docs Value


# Primitive Values

@docs string, name, chars, bool, int, number, null


# Collection Encoders

@docs array, list, object, dict, assocListDict, everySet


# Compiler Type Encoders

@docs maybe, result, nonempty, oneOrMore, jsonPair


# String Encoding

@docs encodeUgly


# File Writing

@docs write, writeUgly


# Conversion

@docs toJsonValue

-}

import Compiler.Data.NonEmptyList as NE
import Compiler.Data.OneOrMore exposing (OneOrMore(..))
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import Json.Encode as Encode
import System.IO as IO
import Task exposing (Task)



-- CORE HELPERS


{-| Encode a dictionary as a JSON array of key-value pairs.
Takes a key comparison function, encoders for keys and values, and produces a JSON array.
-}
assocListDict : (k -> k -> Order) -> (k -> Encode.Value) -> (v -> Encode.Value) -> Dict c k v -> Encode.Value
assocListDict keyComparison keyEncoder valueEncoder =
    Dict.toList keyComparison >> List.reverse >> Encode.list (jsonPair keyEncoder valueEncoder)


{-| Encode a tuple as a JSON object with fields "a" and "b".
-}
jsonPair : (a -> Encode.Value) -> (b -> Encode.Value) -> ( a, b ) -> Encode.Value
jsonPair firstEncoder secondEncoder ( a, b ) =
    Encode.object
        [ ( "a", firstEncoder a )
        , ( "b", secondEncoder b )
        ]


{-| Encode an EverySet as a JSON array.
Takes a comparison function for elements and an encoder for elements.
-}
everySet : (a -> a -> Order) -> (a -> Encode.Value) -> EverySet c a -> Encode.Value
everySet keyComparison encoder =
    EverySet.toList keyComparison >> List.reverse >> Encode.list encoder


{-| Encode a Result value as a JSON object with "type" and "value" fields.
-}
result : (x -> Encode.Value) -> (a -> Encode.Value) -> Result x a -> Encode.Value
result errEncoder successEncoder resultValue =
    case resultValue of
        Ok value ->
            Encode.object
                [ ( "type", Encode.string "Ok" )
                , ( "value", successEncoder value )
                ]

        Err err ->
            Encode.object
                [ ( "type", Encode.string "Err" )
                , ( "value", errEncoder err )
                ]


{-| Encode a Maybe value, using the provided encoder for Just values and null for Nothing.
-}
maybe : (a -> Encode.Value) -> Maybe a -> Encode.Value
maybe encoder maybeValue =
    case maybeValue of
        Just value ->
            encoder value

        Nothing ->
            Encode.null


{-| Encode a non-empty list as a JSON array.
-}
nonempty : (a -> Encode.Value) -> NE.Nonempty a -> Encode.Value
nonempty encoder (NE.Nonempty x xs) =
    Encode.list encoder (x :: xs)


{-| Encode a OneOrMore value as a JSON object.
Single values are encoded with a "one" field, multiple values with "left" and "right" fields.
-}
oneOrMore : (a -> Encode.Value) -> OneOrMore a -> Encode.Value
oneOrMore encoder oneOrMore_ =
    case oneOrMore_ of
        One value ->
            Encode.object [ ( "one", encoder value ) ]

        More left right ->
            Encode.object
                [ ( "left", oneOrMore encoder left )
                , ( "right", oneOrMore encoder right )
                ]



-- VALUES


{-| Custom JSON value representation for the compiler's encoding needs.
-}
type Value
    = Array (List Value)
    | Object (List ( String, Value ))
    | StringVal String
    | Boolean Bool
    | Integer Int
    | Number Float
    | Null


{-| Create a JSON array value.
-}
array : List Value -> Value
array =
    Array


{-| Create a JSON object value from key-value pairs.
-}
object : List ( String, Value ) -> Value
object =
    Object


{-| Create a JSON string value, automatically escaping special characters.
-}
string : String -> Value
string str =
    StringVal (escape str)


{-| Create a JSON string value from a name without escaping.
-}
name : String -> Value
name nm =
    StringVal nm


{-| Create a JSON boolean value.
-}
bool : Bool -> Value
bool =
    Boolean


{-| Create a JSON integer value.
-}
int : Int -> Value
int =
    Integer


{-| Create a JSON number value from a float.
-}
number : Float -> Value
number =
    Number


{-| Create a JSON null value.
-}
null : Value
null =
    Null


{-| Encode a dictionary as a JSON object.
Takes a comparison function for keys, functions to encode keys and values.
-}
dict : (k -> k -> Order) -> (k -> String) -> (v -> Value) -> Dict c k v -> Value
dict keyComparison encodeKey encodeValue pairs =
    Object
        (Dict.toList keyComparison pairs
            |> List.map (\( k, v ) -> ( encodeKey k, encodeValue v ))
        )


{-| Encode a list as a JSON array.
-}
list : (a -> Value) -> List a -> Value
list encodeEntry entries =
    Array (List.map encodeEntry entries)



-- CHARS


{-| Create a JSON string value from characters, escaping special characters.
-}
chars : String -> Value
chars chrs =
    StringVal (escape chrs)


escape : String -> String
escape chrs =
    String.toList chrs
        |> List.map
            (\c ->
                case c of
                    '\u{000D}' ->
                        "\\r"

                    '\n' ->
                        "\\n"

                    '"' ->
                        "\\\""

                    '\\' ->
                        "\\\\"

                    _ ->
                        String.fromChar c
            )
        |> String.concat



-- WRITE TO FILE


{-| Write a JSON value to a file with pretty-printing and a trailing newline.
-}
write : String -> Value -> Task Never ()
write path value =
    fileWriteBuilder path (encode value ++ "\n")


{-| Write a JSON value to a file in compact form without extra whitespace.
-}
writeUgly : String -> Value -> Task Never ()
writeUgly path value =
    fileWriteBuilder path (encodeUgly value)


{-| FIXME Builder.File.writeBuilder
-}
fileWriteBuilder : String -> String -> Task Never ()
fileWriteBuilder =
    IO.writeString



-- ENCODE UGLY


{-| Convert a JSON value to a compact string without extra whitespace.
-}
encodeUgly : Value -> String
encodeUgly value =
    case value of
        Array [] ->
            "[]"

        Array entries ->
            "[" ++ String.join "," (List.map encodeUgly entries) ++ "]"

        Object [] ->
            "{}"

        Object entries ->
            "{" ++ String.join "," (List.map encodeEntryUgly entries) ++ "}"

        StringVal builder ->
            "\"" ++ builder ++ "\""

        Boolean boolean ->
            if boolean then
                "true"

            else
                "false"

        Integer n ->
            String.fromInt n

        Number scientific ->
            String.fromFloat scientific

        Null ->
            "null"


encodeEntryUgly : ( String, Value ) -> String
encodeEntryUgly ( key, entry ) =
    "\"" ++ key ++ "\":" ++ encodeUgly entry



-- ENCODE


encode : Value -> String
encode value =
    encodeHelp "" value


encodeHelp : String -> Value -> String
encodeHelp indent value =
    case value of
        Array [] ->
            "[]"

        Array (first :: rest) ->
            encodeArray indent first rest

        Object [] ->
            "{}"

        Object (first :: rest) ->
            encodeObject indent first rest

        StringVal builder ->
            "\"" ++ builder ++ "\""

        Boolean boolean ->
            if boolean then
                "true"

            else
                "false"

        Integer n ->
            String.fromInt n

        Number scientific ->
            String.fromFloat scientific

        Null ->
            "null"



-- ENCODE ARRAY


encodeArray : String -> Value -> List Value -> String
encodeArray indent first rest =
    let
        newIndent : String
        newIndent =
            indent ++ "    "

        closer : String
        closer =
            "\n" ++ indent ++ "]"

        addValue : Value -> String -> String
        addValue field builder =
            ",\n" ++ newIndent ++ encodeHelp newIndent field ++ builder
    in
    "[\n" ++ newIndent ++ encodeHelp newIndent first ++ List.foldr addValue closer rest



-- ENCODE OBJECT


encodeObject : String -> ( String, Value ) -> List ( String, Value ) -> String
encodeObject indent first rest =
    let
        newIndent : String
        newIndent =
            indent ++ "    "

        closer : String
        closer =
            "\n" ++ indent ++ "}"

        addValue : ( String, Value ) -> String -> String
        addValue field builder =
            ",\n" ++ newIndent ++ encodeField newIndent field ++ builder
    in
    "{\n" ++ newIndent ++ encodeField newIndent first ++ List.foldr addValue closer rest


encodeField : String -> ( String, Value ) -> String
encodeField indent ( key, value ) =
    "\"" ++ key ++ "\": " ++ encodeHelp indent value



-- JSON VALUE


{-| Convert the compiler's custom Value type to the standard Json.Encode.Value type.
-}
toJsonValue : Value -> Encode.Value
toJsonValue value =
    case value of
        Array arr ->
            Encode.list toJsonValue arr

        Object obj ->
            Encode.object (List.map (Tuple.mapSecond toJsonValue) obj)

        StringVal builder ->
            Encode.string builder

        Boolean boolean ->
            Encode.bool boolean

        Integer n ->
            Encode.int n

        Number scientific ->
            Encode.float scientific

        Null ->
            Encode.null
