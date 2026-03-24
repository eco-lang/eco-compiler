module Mlir.Bytecode.StringTable exposing
    ( StringTable
    , collect
    , indexOf
    , encode
    , addString
    , empty
    )

{-| String table for MLIR bytecode.

Collects all unique strings from an MlirModule and assigns sequential indices.
Encodes as: numStrings varint, reverse string lengths as varints, concatenated data.

@docs StringTable, collect, indexOf, encode, addString, empty

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
        , Visibility(..)
        )
import OrderedDict


{-| An indexed string table mapping strings to sequential indices.
-}
type StringTable
    = StringTable
        { strings : Dict String Int
        , ordered : List String
        , nextIndex : Int
        }


{-| Create an empty string table.
-}
empty : StringTable
empty =
    StringTable
        { strings = Dict.empty
        , ordered = []
        , nextIndex = 0
        }


{-| Add a string to the table, returning the updated table.
If the string already exists, the table is unchanged.
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


{-| Get the index of a string in the table.
-}
indexOf : String -> StringTable -> Int
indexOf s (StringTable st) =
    case Dict.get s st.strings of
        Just idx ->
            idx

        Nothing ->
            -- Should not happen if collection was complete
            -1


{-| Collect all strings from an MlirModule into a StringTable.
-}
collect : MlirModule -> StringTable
collect mod =
    let
        st0 =
            empty
                -- Pre-add the "builtin" dialect for the module op
                |> addString "builtin"
                |> addString "module"
    in
    List.foldl collectOp st0 mod.body


collectOp : MlirOp -> StringTable -> StringTable
collectOp op st =
    let
        -- Add operation name parts (dialect.opname)
        st1 =
            addOpName op.name st

        -- Add attribute keys and values
        st2 =
            Dict.foldl collectAttrEntry st1 op.attrs

        -- Add result types
        st3 =
            List.foldl (\( _, t ) acc -> collectType t acc) st2 op.results

        -- Add location strings
        st4 =
            collectLoc op.loc st3

        -- Recurse into regions
        st5 =
            List.foldl collectRegion st4 op.regions
    in
    st5


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


collectAttrEntry : String -> MlirAttr -> StringTable -> StringTable
collectAttrEntry key attr st =
    st
        |> addString key
        |> collectAttr attr


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


collectType : MlirType -> StringTable -> StringTable
collectType ty st =
    case ty of
        I1 ->
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
            -- "!eco.value" -> need both dialect ("eco") and the full struct name
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


collectLoc : Loc -> StringTable -> StringTable
collectLoc (Loc loc) st =
    addString loc.name st


collectRegion : MlirRegion -> StringTable -> StringTable
collectRegion (MlirRegion r) st =
    let
        st1 =
            collectBlock r.entry st
    in
    OrderedDict.foldl (\_ blk acc -> collectBlock blk acc) st1 r.blocks


collectBlock : MlirBlock -> StringTable -> StringTable
collectBlock blk st =
    let
        -- Block argument types
        st1 =
            List.foldl (\( _, t ) acc -> collectType t acc) st blk.args

        -- Body ops
        st2 =
            List.foldl collectOp st1 blk.body

        -- Terminator
        st3 =
            collectOp blk.terminator st2
    in
    st3


{-| Encode the string table as a bytecode section body.
Format: numStrings varint, reverse string lengths varints, concatenated string data.
Strings are unescaped before encoding — the Elm AST stores escape sequences
like \\n as two characters, but bytecode needs the actual bytes.
-}
encode : StringTable -> BE.Encoder
encode (StringTable st) =
    let
        orderedStrings =
            List.reverse st.ordered

        -- Unescape strings for bytecode encoding
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


{-| Unescape a string for bytecode storage.
Converts escape sequences to actual bytes:
\\n → newline, \\t → tab, \\\\ → backslash, \\" → quote
Also handles \\xNN hex escapes and \\uXXXX unicode escapes.
-}
unescapeString : String -> String
unescapeString s =
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

                '\\' :: '\\' :: rest ->
                    go ('\\' :: acc) rest

                '\\' :: '"' :: rest ->
                    go ('"' :: acc) rest

                '\\' :: '\'' :: rest ->
                    go ('\'' :: acc) rest

                '\\' :: '0' :: h1 :: rest ->
                    -- Hex escape \0XY
                    case parseHexByte h1 rest of
                        Just ( code, remaining ) ->
                            go (Char.fromCode code :: acc) remaining

                        Nothing ->
                            go ('0' :: '\\' :: acc) (h1 :: rest)

                '\\' :: 'u' :: h1 :: h2 :: h3 :: h4 :: rest ->
                    -- Unicode escape \uXXXX
                    case parseHex4 h1 h2 h3 h4 of
                        Just code ->
                            go (Char.fromCode code :: acc) rest

                        Nothing ->
                            go ('u' :: '\\' :: acc) (h1 :: h2 :: h3 :: h4 :: rest)

                c :: rest ->
                    go (c :: acc) rest
    in
    go [] (String.toList s)


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


{-| Get the UTF-8 byte length of a string.
-}
stringByteLength : String -> Int
stringByteLength s =
    String.foldl
        (\c acc ->
            let
                code =
                    Char.toCode c
            in
            if code < 0x80 then
                acc + 1

            else if code < 0x0800 then
                acc + 2

            else if code < 0x00010000 then
                acc + 3

            else
                acc + 4
        )
        0
        s
