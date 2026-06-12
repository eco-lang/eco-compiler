module Compiler.AST.StringTable exposing
    ( StringTable
    , disabled, build
    , string, stringDec
    , tableEncoder, tableDecoder
    )

{-| Per-file string interning for `.ecot` / `typed-artifacts.dat`.

Every `.ecot` and `typed-artifacts.dat` artifact begins with a string-table
preamble: one byte of index width (1 / 2 / 4 bytes per reference, chosen at
encode time from table size), a u32 count of unique strings, and `count`
length-prefixed UTF-8 strings (alphabetical for deterministic output). The
body then encodes every formerly-`BE.string`-encoded field as an
index-into-table value of the chosen width.

The same encoder primitives are used by callers that DO NOT want interning
(e.g. legacy `.eci` / `.eco` paths): they pass the `disabled` sentinel, and
`string`/`stringDec` fall through to the regular `BE.string` / `BD.string`
inline encoding. This lets us keep a single set of encoder bodies for both
interning and legacy callers.

Width selection:

  - count ≤ 256 → width = 1 (u8)
  - count ≤ 65,536 → width = 2 (u16, big-endian)
  - otherwise → width = 4 (u32, big-endian)

Determinism: the table is sorted alphabetically before index assignment,
required by the bootstrap byte-equality fixed-point checks.

See ECOT\_002 in design\_docs/invariants.csv.


# Types

@docs StringTable


# Builders

@docs disabled, build


# Field encoders

@docs string, stringDec


# Table preamble

@docs tableEncoder, tableDecoder

-}

import Array exposing (Array)
import Bytes
import Bytes.Decode as BD
import Bytes.Encode as BE
import Dict exposing (Dict)
import Set exposing (Set)
import Utils.Bytes.Decode as UBD
import Utils.Bytes.Encode as UBE



-- TYPES


{-| A built string table. `width` of 0 means "interning disabled — fall back
to inline `BE.string` / `BD.string` encoding".
-}
type alias StringTable =
    { strToIdx : Dict String Int
    , idxToStr : Array String
    , width : Int
    }



-- BUILDERS


{-| Sentinel for callers that want the encoder primitives to fall back to
inline string encoding instead of interning.
-}
disabled : StringTable
disabled =
    { strToIdx = Dict.empty, idxToStr = Array.empty, width = 0 }


{-| Build a table from a set of unique strings. Sorted alphabetically;
index width chosen by count.
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



-- FIELD ENCODERS


{-| Encode a string field. With a real table, emits the index in the chosen
width; with the disabled sentinel, falls back to inline `BE.string`.
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
                        -- Should not happen if collectStrings* matches the encoders.
                        -- Emit 0 as a deterministic fallback so we don't crash mid-encode.
                        0
        in
        if table.width == 1 then
            BE.unsignedInt8 idx

        else if table.width == 2 then
            BE.unsignedInt16 Bytes.BE idx

        else
            BE.unsignedInt32 Bytes.BE idx


{-| Decode a string field. With a real table, reads the index and looks it
up; with the disabled sentinel, falls back to inline `BD.string`.
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


{-| Encode the table preamble: width byte, u32 count, count × length-prefixed
UTF-8 strings in alphabetical order.
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


{-| Decode the table preamble. The returned `StringTable` is ready to be
passed through to body decoders.
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
                                        let
                                            arr : Array String
                                            arr =
                                                Array.fromList strs

                                            dict : Dict String Int
                                            dict =
                                                List.indexedMap (\i s -> ( s, i )) strs
                                                    |> Dict.fromList
                                        in
                                        { strToIdx = dict
                                        , idxToStr = arr
                                        , width = width
                                        }
                                    )
                        )
            )


decodeStrings : Int -> List String -> BD.Decoder (List String)
decodeStrings n acc =
    if n <= 0 then
        BD.succeed (List.reverse acc)

    else
        UBD.string
            |> BD.andThen (\s -> decodeStrings (n - 1) (s :: acc))
