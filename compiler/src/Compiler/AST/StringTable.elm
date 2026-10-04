module Compiler.AST.StringTable exposing
    ( StringTable
    , disabled, build
    , string, stringDec
    , Collector, collectAll, collectSupers, add, collected
    , tableEncoder, tableDecoder
    )

{-| A binary encoding of compiled code repeats the same names, such as module,
type and variable names, many times over, and this module lets an encoding
store each distinct string once and refer to it by number, which is called
_interning_ the strings.

A _string table_ is a list of distinct strings, each identified by its
position, its _index_. An encoding that uses one writes the table first, as a
_preamble_, and then writes each string field of its body as the index of that
string rather than the string itself. The preamble is one byte giving the
_index width_, the number of bytes each index takes in the body; an unsigned
32-bit count of strings; and the strings in index order, each length-prefixed
as `Utils.Bytes.Encode.string` writes it. Every number wider than a byte is
big-endian.

`build` makes a table from a set of strings. Its indices follow ascending
`String` order, so each string's index depends only on which strings are in the
set, not on the order they were gathered in. The width is 1, 2 or 4 bytes, the
smallest of these that can hold every index: 1 byte for up to 256 strings,
including none, 2 bytes for up to 65,536, and 4 bytes beyond that.

The table must hold every string the body will write, so the strings are
gathered before the table is built, in a _collector_ (`collectAll`, `add`,
`collected`), by a walk that must visit every string the encoding will write.
A string missing from the table is not an error: `string` writes index 0 for
it, which belongs to another string or to none, and the bytes decode, without
error, to the wrong string.

`disabled` is a table with index width 0, and with it `string` and
`stringDec` write and read each string inline instead of as an index. A codec
written against a `StringTable` therefore serves both an encoding with a
preamble and one without.

A collector can also be made, by `collectSupers`, to gather only the names
that carry a _super constraint_: the restriction an Elm type variable is under
when its name starts with `number`, `comparable`, `appendable` or
`compappend`, as the tests in `Compiler.Data.Name` define it. Such a collector
finds those names without building the set of every string.


# Types

@docs StringTable


# Builders

@docs disabled, build


# Field encoders

@docs string, stringDec


# Collection

@docs Collector, collectAll, collectSupers, add, collected


# Table preamble

@docs tableEncoder, tableDecoder

-}

import Array exposing (Array)
import Bytes
import Bytes.Decode as BD
import Bytes.Encode as BE
import Compiler.Data.Name as Name
import Dict exposing (Dict)
import Set exposing (Set)
import Utils.Bytes.Decode as UBD
import Utils.Bytes.Encode as UBE



-- TYPES


{-| A string table: the strings an encoding refers to by index, and the index
width it writes them with.

`width` 0 means no table at all, and strings are written and read inline (see
`disabled`). A table read by `tableDecoder` has an empty `strToIdx`, so, unless
its width is 0, it can be used to decode but not to encode.

-}
type alias StringTable =
    { strToIdx : Dict String Int
    , idxToStr : Array String
    , width : Int
    }



-- BUILDERS


{-| The table that turns string interning off. Its index width is 0, so `string`
writes each string inline, length-prefixed as `Utils.Bytes.Encode.string`
writes it, and `stringDec` reads it back the same way.
-}
disabled : StringTable
disabled =
    { strToIdx = Dict.empty, idxToStr = Array.empty, width = 0 }


{-| Builds a table holding `strings`, indexed from 0 in ascending `String` order.

The index width is 1 byte for up to 256 strings, 2 bytes for up to 65,536, and
4 bytes beyond that. An empty set also gets width 1, so a built table is never
mistaken for `disabled`.

-}
build : Set String -> StringTable
build strings =
    let
        sorted : List String
        sorted =
            Set.toList strings

        count : Int
        count =
            List.length sorted

        chosenWidth : Int
        chosenWidth =
            if count == 0 then
                1

            else if count <= 256 then
                1

            else if count <= 65536 then
                2

            else
                4

        ( finalDict, finalArr ) =
            List.foldl
                (\s ( d, a ) ->
                    ( Dict.insert s (Array.length a) d
                    , Array.push s a
                    )
                )
                ( Dict.empty, Array.empty )
                sorted
    in
    { strToIdx = finalDict
    , idxToStr = finalArr
    , width = chosenWidth
    }



-- COLLECTION


{-| A set of strings being gathered, string by string, together with the rule
for which strings it keeps.

A collector is made by `collectAll`, which keeps every string it is given, or
by `collectSupers`, which keeps only names that carry a super constraint. The
rule is fixed when it is made. `add` gives it one string and `collected`
returns what it has kept.

-}
type Collector
    = CollectAll (Set String)
    | CollectSupers (Set String)


{-| An empty collector that keeps every string it is given.
-}
collectAll : Collector
collectAll =
    CollectAll Set.empty


{-| An empty collector that keeps only the strings starting with `number`,
`comparable`, `appendable` or `compappend`, the names that carry a super
constraint.

It tests the string alone, so it keeps any such string it is given, whether or
not it names a type variable.

-}
collectSupers : Collector
collectSupers =
    CollectSupers Set.empty


{-| Returns the collector `c` with `s` added, if `c` keeps strings like `s`.

When `s` is already present, or is not one `c` keeps, `c` itself is returned.
A repeated string therefore builds no new set.

-}
add : String -> Collector -> Collector
add s c =
    case c of
        CollectAll set ->
            if Set.member s set then
                c

            else
                CollectAll (Set.insert s set)

        CollectSupers set ->
            if isSuperName s && not (Set.member s set) then
                CollectSupers (Set.insert s set)

            else
                c


{-| Returns the strings the collector has kept.
-}
collected : Collector -> Set String
collected c =
    case c of
        CollectAll set ->
            set

        CollectSupers set ->
            set


{-| Tells whether `s` carries a super constraint, by the four prefix tests of
`Compiler.Data.Name`.

These are the same four tests for which
`Compiler.AST.TypedOptimized.superOfName` returns `Just`, and the two must stay
in step: a name this rejects is dropped by a `collectSupers` collector, whatever
`superOfName` says of it.

-}
isSuperName : String -> Bool
isSuperName s =
    Name.isNumberType s
        || Name.isComparableType s
        || Name.isAppendableType s
        || Name.isCompappendType s



-- FIELD ENCODERS


{-| Produces an encoder for the string `s` as `table` writes it: its index in
the table's index width, or, with `disabled`, the string itself inline.

A string that is not in the table is written as index 0, which belongs to
another string or to none, so the bytes still decode but to the wrong string.
A table read by `tableDecoder`, unless its width is 0, holds no index for any
string, so it writes index 0 for all of them.

-}
string : StringTable -> String -> BE.Encoder
string table s =
    if table.width == 0 then
        UBE.string s

    else
        let
            idx : Int
            idx =
                case Dict.get s table.strToIdx of
                    Just i ->
                        i

                    Nothing ->
                        0
        in
        if table.width == 1 then
            BE.unsignedInt8 idx

        else if table.width == 2 then
            BE.unsignedInt16 Bytes.BE idx

        else
            BE.unsignedInt32 Bytes.BE idx


{-| Produces a decoder for a string written by `string` with the same table: an
index in the table's index width, looked up in `table`, or, with `disabled`, a
string read inline.

An index with no string in the table decodes as the empty string, not as a
failure.

-}
stringDec : StringTable -> BD.Decoder String
stringDec table =
    if table.width == 0 then
        UBD.string

    else
        let
            idxDecoder : BD.Decoder Int
            idxDecoder =
                if table.width == 1 then
                    BD.unsignedInt8

                else if table.width == 2 then
                    BD.unsignedInt16 Bytes.BE

                else
                    BD.unsignedInt32 Bytes.BE
        in
        BD.map
            (\i ->
                case Array.get i table.idxToStr of
                    Just s ->
                        s

                    Nothing ->
                        ""
            )
            idxDecoder



-- TABLE PREAMBLE


{-| Produces an encoder for the preamble of `table`: the index width as one
byte, the number of strings as an unsigned 32-bit big-endian number, and the
strings in index order, each length-prefixed.
-}
tableEncoder : StringTable -> BE.Encoder
tableEncoder table =
    let
        strings : List String
        strings =
            Array.toList table.idxToStr
    in
    BE.sequence
        [ BE.unsignedInt8 table.width
        , BE.unsignedInt32 Bytes.BE (List.length strings)
        , BE.sequence (List.map UBE.string strings)
        ]


{-| A decoder for a preamble written by `tableEncoder`, giving the table that
`stringDec` needs to read the body that follows.

Unless its width is 0, the table it gives can decode but not encode: its
`strToIdx` is empty, so `string` would write index 0 for every string. The
width byte is taken as it is, so a preamble written from `disabled` gives a
table that reads strings inline.

-}
tableDecoder : BD.Decoder StringTable
tableDecoder =
    BD.unsignedInt8
        |> BD.andThen
            (\width ->
                BD.unsignedInt32 Bytes.BE
                    |> BD.andThen
                        (\count ->
                            decodeStrings count []
                                |> BD.map
                                    (\strs ->
                                        { strToIdx = Dict.empty
                                        , idxToStr = Array.fromList strs
                                        , width = width
                                        }
                                    )
                        )
            )


{-| Produces a decoder that reads `n` length-prefixed strings and returns the
strings of `acc0`, which holds earlier ones newest first, in reverse, followed by
the `n` new strings in the order they were read.

It reads with `BD.loop` rather than one `andThen` per string, so that a long
table does not nest one decoder call inside another for every string it holds.

-}
decodeStrings : Int -> List String -> BD.Decoder (List String)
decodeStrings n acc0 =
    BD.loop ( n, acc0 )
        (\( k, acc ) ->
            if k <= 0 then
                BD.succeed (BD.Done (List.reverse acc))

            else
                BD.map (\s -> BD.Loop ( k - 1, s :: acc )) UBD.string
        )
