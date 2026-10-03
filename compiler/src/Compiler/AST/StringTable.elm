module Compiler.AST.StringTable exposing
    ( StringTable
    , disabled, build
    , string, stringDec
    , Collector, collectAll, collectSupers, add, collected
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



-- COLLECTION


{-| Accumulator of the string collectors (ECOT\_002).

  - `CollectAll` gathers every emitted string, for the string-table build.
  - `CollectSupers` keeps only the strings `TOpt.superOfName` maps to `Just`, so the
    sweep that computes `varSupers` never builds the module-wide set
    (cache-serialization plan S2).

-}
type Collector
    = CollectAll (Set String)
    | CollectSupers (Set String)


{-| A collector gathering every string.
-}
collectAll : Collector
collectAll =
    CollectAll Set.empty


{-| A collector keeping only super-constrained type-variable names.
-}
collectSupers : Collector
collectSupers =
    CollectSupers Set.empty


{-| Add one emitted string.

On a hit, return the SAME collector: no path copy and no rebalance, which
`Set.insert` still pays for a present key. 99.9 % of collector inserts are
repeats (plan S1).

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


{-| The collected strings.
-}
collected : Collector -> Set String
collected c =
    case c of
        CollectAll set ->
            set

        CollectSupers set ->
            set


{-| MUST be the exact disjunction of the `Just` cases of `TOpt.superOfName`
(pinned by `VarSupersEquivalenceTest`).
-}
isSuperName : String -> Bool
isSuperName s =
    Name.isNumberType s
        || Name.isComparableType s
        || Name.isAppendableType s
        || Name.isCompappendType s



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

A decoded table is DECODE-ONLY: its `strToIdx` is left empty (the decoders read
only `idxToStr`), so `string` on it would emit index 0 for every string.

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


decodeStrings : Int -> List String -> BD.Decoder (List String)
decodeStrings n acc0 =
    -- BD.loop, not a recursive andThen chain: the chain overflows the JS stack
    -- (bootstrap stages, elm-test) at tens of thousands of strings.
    BD.loop ( n, acc0 )
        (\( k, acc ) ->
            if k <= 0 then
                BD.succeed (BD.Done (List.reverse acc))

            else
                BD.map (\s -> BD.Loop ( k - 1, s :: acc )) UBD.string
        )
