module Compiler.Json.Encode exposing
    ( Value
    , string, name, chars, bool, int, null
    , array, list, object
    , stdDict
    , encodeUgly
    , write, writeUgly
    )

{-| The compiler writes JSON of its own, and this module builds that JSON and
prints it as text.

A `Value` is a JSON document held as a tree. Its only numbers are integers.

Printing adds no escaping. A string is written between quotes exactly as the
`Value` holds it, and so is every object key. Whether a string is escaped is
therefore decided when its `Value` is made: `string` and `chars` escape their
argument, and `name` takes its argument as already safe to print. Escaping
covers only carriage return, newline, double quote and backslash. A tab or any
other character below U+0020 is written as it is, which is not valid JSON, and
object keys are never escaped at all.

Text that `Compiler.Json.Decode.string` returns still has its escapes in it, as
that module describes, so it goes back out through `name`. Passing it to
`string` escapes it a second time.

A `Value` prints in one of two layouts. The compact layout, from `encodeUgly`
and `writeUgly`, has no whitespace between tokens. The pretty layout, from
`write`, puts each array element and object field on a line of its own,
indented four spaces deeper than the line that opens its array or object, and
writes a space after each key's colon. An empty array or object prints as `[]`
or `{}` in both layouts.


# Value Type

@docs Value


# Primitive Values

@docs string, name, chars, bool, int, null


# Collection Encoders

@docs array, list, object


# Dictionaries

@docs stdDict


# String Encoding

@docs encodeUgly


# File Writing

@docs write, writeUgly

-}

import Dict
import System.IO as IO
import Task exposing (Task)



-- ====== VALUES ======


{-| A JSON document, as a tree of arrays, objects, strings, booleans, integers
and nulls.

`Array` holds its elements in order.

`Object` holds its fields in order, and that is the order they are printed in.
Nothing removes a repeated key, so a key given twice is printed twice.

`StringVal` holds text exactly as it will appear between the quotes, so it must
already be escaped. Building one directly skips escaping, as `name` does;
`string` and `chars` escape their argument first.

`Boolean` and `Integer` print as the JSON literal for their payload, and `Null`
as `null`.

-}
type Value
    = Array (List Value)
    | Object (List ( String, Value ))
    | StringVal String
    | Boolean Bool
    | Integer Int
    | Null


{-| Returns a JSON array of the given elements, in order.
-}
array : List Value -> Value
array =
    Array


{-| Returns a JSON object with the given fields, in order. The keys are printed
as given, without escaping, and a repeated key is kept.
-}
object : List ( String, Value ) -> Value
object =
    Object


{-| Returns a JSON string holding `str`, with carriage returns, newlines, double
quotes and backslashes escaped. No other character is escaped.
-}
string : String -> Value
string str =
    StringVal (escape str)


{-| Returns a JSON string holding `nm` exactly as given, without escaping. It is
for text that is already safe to print between quotes, such as an identifier or
text that is still escaped.
-}
name : String -> Value
name nm =
    StringVal nm


{-| Returns a JSON boolean.
-}
bool : Bool -> Value
bool =
    Boolean


{-| Returns a JSON integer.
-}
int : Int -> Value
int =
    Integer


{-| The JSON `null`.
-}
null : Value
null =
    Null


{-| Returns a JSON object with one field per entry of `pairs`, in ascending
order of the dictionary's keys (not of the text `encodeKey` turns them into).
Each key is turned into text by `encodeKey`, which is printed without escaping,
and each value by `encodeValue`.
-}
stdDict : (comparable -> String) -> (v -> Value) -> Dict.Dict comparable v -> Value
stdDict encodeKey encodeValue pairs =
    Object
        (Dict.toList pairs
            |> List.map (\( k, v ) -> ( encodeKey k, encodeValue v ))
        )


{-| Returns a JSON array with one element per entry, each encoded by
`encodeEntry`, in order.
-}
list : (a -> Value) -> List a -> Value
list encodeEntry entries =
    Array (List.map encodeEntry entries)



-- ====== CHARS ======


{-| Returns a JSON string holding `chrs`, escaped exactly as `string` escapes
it.
-}
chars : String -> Value
chars chrs =
    StringVal (escape chrs)


{-| Returns `chrs` with each carriage return, newline, double quote and
backslash replaced by its two-character JSON escape. Every other character,
including a tab or another control character, is kept as it is.
-}
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



-- ====== WRITE TO FILE ======


{-| Writes `value` to the file at `path` in the pretty layout, followed by a
newline. The program crashes if the write fails.
-}
write : String -> Value -> Task Never ()
write path value =
    fileWriteBuilder path (encode value ++ "\n")


{-| Writes `value` to the file at `path` in the compact layout, with no newline
after it. The program crashes if the write fails.
-}
writeUgly : String -> Value -> Task Never ()
writeUgly path value =
    fileWriteBuilder path (encodeUgly value)


{-| Writes `content` to the file at `path`, crashing as `System.IO.crashOnError`
describes if the write fails.
-}
fileWriteBuilder : String -> String -> Task Never ()
fileWriteBuilder path content =
    IO.writeString path content
        |> IO.crashOnError



-- ====== ENCODE UGLY ======


{-| Prints `value` in the compact layout, with no whitespace between tokens and
no newline at the end.
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

        Null ->
            "null"


{-| Prints one object field in the compact layout: the quoted key, a colon and
the value.
-}
encodeEntryUgly : ( String, Value ) -> String
encodeEntryUgly ( key, entry ) =
    "\"" ++ key ++ "\":" ++ encodeUgly entry



-- ====== ENCODE ======


{-| Prints `value` in the pretty layout, starting at no indentation and with no
newline at the end.
-}
encode : Value -> String
encode value =
    encodeHelp "" value


{-| Prints `value` in the pretty layout, given that the line it starts on is
indented by `indent`. The first line of the result carries no indentation of its
own; the lines after it are indented relative to `indent`.
-}
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

        Null ->
            "null"



-- ====== ENCODE ARRAY ======


{-| Prints a non-empty array, `first` followed by `rest`, in the pretty layout:
each element on its own line indented four spaces past `indent`, and the closing
bracket on a line indented by `indent`.
-}
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



-- ====== ENCODE OBJECT ======


{-| Prints a non-empty object, `first` followed by `rest`, in the pretty layout:
each field on its own line indented four spaces past `indent`, and the closing
brace on a line indented by `indent`.
-}
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


{-| Prints one object field in the pretty layout: the quoted key, a colon and a
space, then the value printed as starting on a line indented by `indent`.
-}
encodeField : String -> ( String, Value ) -> String
encodeField indent ( key, value ) =
    "\"" ++ key ++ "\": " ++ encodeHelp indent value
