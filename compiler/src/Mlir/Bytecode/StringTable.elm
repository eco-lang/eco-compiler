module Mlir.Bytecode.StringTable exposing (StringTable, collect, indexOf, encode, addString, empty, collectOp)

{-| MLIR bytecode refers to many of its strings, such as dialect names,
operation names and the text of string attributes, by their index in one string
section, and this module builds that section and writes it.

A `StringTable` gives each distinct string an index. Indices are handed out
from 0 in the order strings are first added, and adding a string that is
already there changes nothing. `encode` writes the strings in that same order,
so a string's index is its position in the section. An index never changes once
given, so it can be written before the table is complete.

`collect` and `collectOp` walk operations and add the strings found in them.
Nothing checks that a string being looked up was added: `indexOf` then returns
-1, which `Mlir.Bytecode.VarInt.encodeVarInt` writes like any other number, so
a missed string makes a corrupt file rather than an error.

The text of a `StringAttr` keeps its escape sequences written out, as
`Mlir.Mlir.MlirAttr` describes. The table stores and looks up strings as they
are given, and `encode` replaces the escapes with the characters they stand for
only as it writes each string. It does this to every string in the table,
whatever it came from. Two escaped spellings of the same text are therefore two
entries.

@docs StringTable, collect, indexOf, encode, addString, empty, collectOp

-}

import Bytes.Encode as BE
import Dict exposing (Dict)
import Mlir.Bytecode.VarInt exposing (encodeVarInt)
import Mlir.Loc exposing (Loc(..))
import Mlir.Mlir
    exposing
        ( MlirAttr(..)
        , MlirBlock
        , MlirModule
        , MlirOp
        , MlirRegion(..)
        , MlirType(..)
        )
import OrderedDict


{-| A set of distinct strings, each with the index it has in the bytecode string
section.

The indices run from 0 with no gaps, in the order the strings were first
added, and a string's index never changes once given. A table is made by
`empty` or `collect`, and grows through `addString` and `collectOp`.

-}
type StringTable
    = StringTable
        { strings : Dict String Int
        , ordered : List String -- most recently added first
        , nextIndex : Int
        }


{-| The table with no strings in it.
-}
empty : StringTable
empty =
    StringTable
        { strings = Dict.empty
        , ordered = []
        , nextIndex = 0
        }


{-| Adds `s` to the table with the next free index, or returns the table
unchanged if `s` is already in it.
-}
addString : String -> StringTable -> StringTable
addString s (StringTable st) =
    case Dict.get s st.strings of
        Just _ ->
            StringTable st

        Nothing ->
            StringTable
                { strings = Dict.insert s st.nextIndex st.strings
                , ordered = s :: st.ordered
                , nextIndex = st.nextIndex + 1
                }


{-| Returns the index of `s` in the table, or -1 if `s` was never added.

`Mlir.Bytecode.VarInt.encodeVarInt` does not reject a -1; it writes it in the
9-byte form, so an index taken for a missing string corrupts the file.

-}
indexOf : String -> StringTable -> Int
indexOf s (StringTable st) =
    case Dict.get s st.strings of
        Just idx ->
            idx

        Nothing ->
            -1


{-| Builds the table for a whole module.

It starts with `builtin` and `module`, the dialect and name of MLIR's module
operation, and then adds what `collectOp` adds for each operation of
`mod.body`, in order. The module's own location is not visited.

-}
collect : MlirModule -> StringTable
collect mod =
    let
        st0 =
            empty
                |> addString "builtin"
                |> addString "module"
    in
    List.foldl collectOp st0 mod.body


{-| Adds the strings of `op` and of every operation nested in its regions.

For each operation these are, in order: the part of its name before the first
`.`, which is its dialect, and the rest of its name (a name with no `.` is
added whole, together with the empty string); each attribute's name and the
strings in its value; the strings in its result types; and the file name of its
location, which for `Mlir.Loc.unknown` is `"unknown"`. Its regions follow,
each entry block first and then the other blocks in their stored order, and in
each block the argument types, the body operations and the terminator.

An attribute value contributes the text of a `StringAttr` or `SymbolRefAttr`,
`"private"` for a `VisibilityAttr`, the strings in the type of a `TypeAttr` or
`TypedFloatAttr`, and those of every element of an `ArrayAttr`. The type an
`IntAttr` or `ArrayAttr` carries is not visited. A type contributes strings
only through a `NamedStruct`, which adds its dialect, the text before the
first `.`, and its full name. Operand names and successor labels are not
added.

-}
collectOp : MlirOp -> StringTable -> StringTable
collectOp op st =
    let
        st1 =
            addOpName op.name st

        st2 =
            Dict.foldl collectAttrEntry st1 op.attrs

        st3 =
            List.foldl (\( _, t ) acc -> collectType t acc) st2 op.results

        st4 =
            collectLoc op.loc st3
    in
    List.foldl collectRegion st4 op.regions


{-| Adds the two parts of an operation name: the dialect before the first `.`,
and everything after it. A name with no `.` is added whole as the dialect,
together with the empty string as the rest.
-}
addOpName : String -> StringTable -> StringTable
addOpName name st =
    case String.split "." name of
        dialect :: rest ->
            let
                opSuffix =
                    String.join "." rest
            in
            st
                |> addString dialect
                |> addString opSuffix

        _ ->
            addString name st


{-| Adds an attribute's name `key` and the strings in its value.
-}
collectAttrEntry : String -> MlirAttr -> StringTable -> StringTable
collectAttrEntry key attr st =
    st
        |> addString key
        |> collectAttr attr


{-| Adds the strings in an attribute value: the text of a `StringAttr` or
`SymbolRefAttr`, `"private"` for a `VisibilityAttr`, the strings in the type of
a `TypeAttr` or `TypedFloatAttr`, and those of every element of an
`ArrayAttr`. The type an `IntAttr` or `ArrayAttr` carries is not visited.
-}
collectAttr : MlirAttr -> StringTable -> StringTable
collectAttr attr st =
    case attr of
        StringAttr s ->
            addString s st

        BoolAttr _ ->
            st

        IntAttr _ _ ->
            st

        TypedFloatAttr _ t ->
            collectType t st

        TypeAttr t ->
            collectType t st

        ArrayAttr _ items ->
            List.foldl collectAttr st items

        SymbolRefAttr s ->
            addString s st

        VisibilityAttr _ ->
            addString "private" st

        UnitAttr ->
            st


{-| Adds the strings in a type. Only a `NamedStruct` has any: its dialect, the
text before the first `.`, and its full name. A `FunctionType` adds those of
its input and result types.
-}
collectType : MlirType -> StringTable -> StringTable
collectType ty st =
    case ty of
        I1 ->
            st

        I8 ->
            st

        I16 ->
            st

        I32 ->
            st

        I64 ->
            st

        F64 ->
            st

        NamedStruct s ->
            case String.split "." s of
                dialect :: _ ->
                    st |> addString dialect |> addString s

                _ ->
                    addString s st

        FunctionType sig ->
            let
                st1 =
                    List.foldl collectType st sig.inputs
            in
            List.foldl collectType st1 sig.results


{-| Adds the file name of a location. `Mlir.Loc.unknown` is not skipped: its
name, `"unknown"`, is added like any other.
-}
collectLoc : Loc -> StringTable -> StringTable
collectLoc (Loc loc) st =
    addString loc.name st


{-| Adds the strings of a region's entry block, then of its other blocks in
their stored order.
-}
collectRegion : MlirRegion -> StringTable -> StringTable
collectRegion (MlirRegion r) st =
    let
        st1 =
            collectBlock r.entry st
    in
    OrderedDict.foldl (\_ blk acc -> collectBlock blk acc) st1 r.blocks


{-| Adds the strings of a block's argument types, its body operations and its
terminator.
-}
collectBlock : MlirBlock -> StringTable -> StringTable
collectBlock blk st =
    let
        st1 =
            List.foldl (\( _, t ) acc -> collectType t acc) st blk.args

        st2 =
            List.foldl collectOp st1 blk.body
    in
    collectOp blk.terminator st2


{-| Creates an encoder for the contents of the string section, without the
section's own header.

It writes the number of strings, then each string's length in bytes, last
string first, then the strings themselves in index order, each followed by a
zero byte. Each length counts that zero byte. The numbers are PrefixVarInts
(see `Mlir.Bytecode.VarInt`).

Each string is written with its escape sequences replaced by the characters
they stand for: `\n`, `\t`, `\\`, `\"` and `\'`; `\u` and four hex digits,
which becomes the character with that code; and `\0` and two hex digits,
likewise. A backslash that starts anything else, such as `\r`, is written as it
is. The lengths are measured on the strings as written, with
`Bytes.Encode.getStringWidth`, the function `Bytes.Encode.string` sizes its own
output with, so each length matches the bytes that follow.

-}
encode : StringTable -> BE.Encoder
encode (StringTable st) =
    let
        orderedStrings =
            List.reverse st.ordered

        unescapedStrings =
            List.map unescapeString orderedStrings

        numStrings =
            st.nextIndex

        reverseLengths =
            unescapedStrings
                |> List.map (\s -> encodeVarInt (stringByteLength s + 1))
                |> List.reverse

        stringData =
            unescapedStrings
                |> List.map (\s -> BE.sequence [ BE.string s, BE.unsignedInt8 0x00 ])
    in
    BE.sequence
        (encodeVarInt numStrings
            :: reverseLengths
            ++ stringData
        )


{-| Returns `s` with its escape sequences replaced by the characters they stand
for, as `unescapeStringSlow` describes.

A string with no backslash is returned as it is, without being rebuilt
character by character, which would give the same string.

-}
unescapeString : String -> String
unescapeString s =
    if not (String.contains "\\" s) then
        s

    else
        unescapeStringSlow s


{-| Returns `s` with each escape sequence replaced by the character it stands
for.

`\n`, `\r`, `\t`, `\\`, `\"` and `\'` become a newline, a carriage return, a tab, a
backslash, a double quote and a single quote. `\u` followed by four hex digits becomes the
character with that code. Each such escape is converted on its own; a
character above U+FFFF arrives as two escapes, one for each half of a UTF-16
surrogate pair, and the two halves end up next to each other in the result.
`\0` followed by two hex digits becomes the character with that code.

A backslash that starts anything else, including `\u` or `\0` without enough
hex digits after it, is kept, and the text after it is read as usual.

-}
unescapeStringSlow : String -> String
unescapeStringSlow s =
    let
        go : List Char -> List Char -> String
        go acc chars =
            case chars of
                [] ->
                    String.fromList (List.reverse acc)

                '\\' :: 'n' :: rest ->
                    go (Char.fromCode 0x0A :: acc) rest

                '\\' :: 't' :: rest ->
                    go (Char.fromCode 0x09 :: acc) rest

                '\\' :: 'r' :: rest ->
                    go (Char.fromCode 0x0D :: acc) rest

                '\\' :: '\\' :: rest ->
                    go ('\\' :: acc) rest

                '\\' :: '"' :: rest ->
                    go ('"' :: acc) rest

                '\\' :: '\'' :: rest ->
                    go ('\'' :: acc) rest

                '\\' :: '0' :: h1 :: rest ->
                    case parseHexByte h1 rest of
                        Just ( code, remaining ) ->
                            go (Char.fromCode code :: acc) remaining

                        Nothing ->
                            go ('0' :: '\\' :: acc) (h1 :: rest)

                '\\' :: 'u' :: h1 :: h2 :: h3 :: h4 :: rest ->
                    case parseHex4 h1 h2 h3 h4 of
                        Just code ->
                            go (Char.fromCode code :: acc) rest

                        Nothing ->
                            go ('u' :: '\\' :: acc) (h1 :: h2 :: h3 :: h4 :: rest)

                c :: rest ->
                    go (c :: acc) rest
    in
    go [] (String.toList s)


{-| Reads `h1` and the first character of `rest` as two hex digits. Returns the
number they spell and the characters after them, or `Nothing` if `rest` is
empty or either character is not a hex digit.
-}
parseHexByte : Char -> List Char -> Maybe ( Int, List Char )
parseHexByte h1 rest =
    case rest of
        h2 :: remaining ->
            case ( hexDigit h1, hexDigit h2 ) of
                ( Just d1, Just d2 ) ->
                    Just ( d1 * 16 + d2, remaining )

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Returns the number four hex digits spell, most significant first, or
`Nothing` if any of them is not a hex digit.
-}
parseHex4 : Char -> Char -> Char -> Char -> Maybe Int
parseHex4 h1 h2 h3 h4 =
    case ( hexDigit h1, hexDigit h2 ) of
        ( Just d1, Just d2 ) ->
            case ( hexDigit h3, hexDigit h4 ) of
                ( Just d3, Just d4 ) ->
                    Just (d1 * 4096 + d2 * 256 + d3 * 16 + d4)

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Returns the value of a hex digit, `0` to `9`, `A` to `F` or `a` to `f`, or
`Nothing` for any other character.
-}
hexDigit : Char -> Maybe Int
hexDigit c =
    let
        code =
            Char.toCode c
    in
    if code >= 48 && code <= 57 then
        Just (code - 48)

    else if code >= 65 && code <= 70 then
        Just (code - 55)

    else if code >= 97 && code <= 102 then
        Just (code - 87)

    else
        Nothing


{-| Returns the number of bytes `BE.string` writes for `s`.

The string section records each string's length separately from its bytes, so
the two must agree exactly. This uses `BE.getStringWidth`, the function
`BE.string` itself sizes its output with, so they agree by construction.

-}
stringByteLength : String -> Int
stringByteLength s =
    BE.getStringWidth s
