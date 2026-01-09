module Compiler.Elm.ModuleName exposing
    ( Raw
    , toFilePath, toHyphenPath
    , encode, decoder
    , compareCanonical, toComparableCanonical
    , basics, char, string, maybe, result, list, array, dict, tuple, platform, cmd, sub, debug
    , virtualDom
    , jsonDecode, jsonEncode
    , bytes
    , webgl, texture, vector2, vector3, vector4, matrix4
    , canonicalEncoder, canonicalDecoder, rawEncoder, rawDecoder
    )

{-| Utilities for working with Elm module names in their raw and canonical forms.

This module provides parsers, encoders, decoders, and constants for Elm module names.
Raw module names are dotted identifiers like "List" or "Dict.Extra". Canonical module
names include both the package name and module name, fully qualifying the module.


# Types

@docs Raw


# Path Conversion

@docs toFilePath, toHyphenPath


# JSON Encoding/Decoding

@docs encode, decoder


# Canonical Module Names

@docs compareCanonical, toComparableCanonical


# Core Modules

@docs basics, char, string, maybe, result, list, array, dict, tuple, platform, cmd, sub, debug


# HTML Modules

@docs virtualDom


# JSON Modules

@docs jsonDecode, jsonEncode


# Bytes Modules

@docs bytes


# WebGL Modules

@docs webgl, texture, vector2, vector3, vector4, matrix4


# Binary Encoding/Decoding

@docs canonicalEncoder, canonicalDecoder, rawEncoder, rawDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.Package as Pkg
import Compiler.Json.Decode as D
import Compiler.Json.Encode as E
import Compiler.Parse.Primitives as P
import Compiler.Parse.Variable as Var
import System.TypeCheck.IO exposing (Canonical(..))
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- ====== RAW ======


{-| A raw module name represented as a dotted identifier string.
Examples: "List", "Dict.Extra", "Html.Attributes"
-}
type alias Raw =
    Name


{-| Convert a raw module name to a file path by replacing dots with slashes.
Example: "Html.Attributes" becomes "Html/Attributes"
-}
toFilePath : Raw -> String
toFilePath name =
    String.map
        (\c ->
            if c == '.' then
                -- TODO System.FilePath.pathSeparator
                '/'

            else
                c
        )
        name


{-| Convert a raw module name to a hyphenated path by replacing dots with hyphens.
Example: "Html.Attributes" becomes "Html-Attributes"
-}
toHyphenPath : Raw -> String
toHyphenPath name =
    String.map
        (\c ->
            if c == '.' then
                '-'

            else
                c
        )
        name



-- ====== JSON ======


{-| Encode a raw module name as a JSON string.
-}
encode : Raw -> E.Value
encode =
    E.string


{-| Decode a raw module name from a JSON string, validating it matches module name syntax.
-}
decoder : D.Decoder ( Int, Int ) Raw
decoder =
    D.customString parser Tuple.pair



-- ====== PARSER ======


parser : P.Parser ( Int, Int ) Raw
parser =
    P.Parser
        (\(P.State st) ->
            let
                ( isGood, newPos, newCol ) =
                    chompStart st.src st.pos st.end st.col
            in
            if isGood && (newPos - st.pos) < 256 then
                let
                    newState : P.State
                    newState =
                        P.State { st | pos = newPos, col = newCol }
                in
                P.Cok (String.slice st.pos newPos st.src) newState

            else if st.col == newCol then
                P.Eerr st.row newCol Tuple.pair

            else
                P.Cerr st.row newCol Tuple.pair
        )


chompStart : String -> Int -> Int -> Int -> ( Bool, Int, Int )
chompStart src pos end col =
    let
        width : Int
        width =
            Var.getUpperWidth src pos end
    in
    if width == 0 then
        ( False, pos, col )

    else
        chompInner src (pos + width) end (col + 1)


chompInner : String -> Int -> Int -> Int -> ( Bool, Int, Int )
chompInner src pos end col =
    if pos >= end then
        ( True, pos, col )

    else
        let
            word : Char
            word =
                P.unsafeIndex src pos

            width : Int
            width =
                Var.getInnerWidthHelp src pos end word
        in
        if width == 0 then
            if word == '.' then
                chompStart src (pos + 1) end (col + 1)

            else
                ( True, pos, col )

        else
            chompInner src (pos + width) end (col + 1)



-- ====== INSTANCES ======


{-| Compare two canonical module names, first by module name then by package name.
-}
compareCanonical : Canonical -> Canonical -> Order
compareCanonical (Canonical pkg1 name1) (Canonical pkg2 name2) =
    case compare name1 name2 of
        LT ->
            LT

        EQ ->
            Pkg.compareName pkg1 pkg2

        GT ->
            GT


{-| Convert a canonical module name to a comparable list of strings [author, project, name].
Useful for sorting and comparison in data structures.
-}
toComparableCanonical : Canonical -> List String
toComparableCanonical (Canonical ( author, project ) name) =
    [ author, project, name ]



-- ====== CORE ======


{-| Canonical name for the Basics module from elm/core.
-}
basics : Canonical
basics =
    Canonical Pkg.core Name.basics


{-| Canonical name for the Char module from elm/core.
-}
char : Canonical
char =
    Canonical Pkg.core Name.char


{-| Canonical name for the String module from elm/core.
-}
string : Canonical
string =
    Canonical Pkg.core Name.string


{-| Canonical name for the Maybe module from elm/core.
-}
maybe : Canonical
maybe =
    Canonical Pkg.core Name.maybe


{-| Canonical name for the Result module from elm/core.
-}
result : Canonical
result =
    Canonical Pkg.core Name.result


{-| Canonical name for the List module from elm/core.
-}
list : Canonical
list =
    Canonical Pkg.core Name.list


{-| Canonical name for the Array module from elm/core.
-}
array : Canonical
array =
    Canonical Pkg.core Name.array


{-| Canonical name for the Dict module from elm/core.
-}
dict : Canonical
dict =
    Canonical Pkg.core Name.dict


{-| Canonical name for the Tuple module from elm/core.
-}
tuple : Canonical
tuple =
    Canonical Pkg.core Name.tuple


{-| Canonical name for the Platform module from elm/core.
-}
platform : Canonical
platform =
    Canonical Pkg.core Name.platform


{-| Canonical name for the Platform.Cmd module from elm/core.
-}
cmd : Canonical
cmd =
    Canonical Pkg.core "Platform.Cmd"


{-| Canonical name for the Platform.Sub module from elm/core.
-}
sub : Canonical
sub =
    Canonical Pkg.core "Platform.Sub"


{-| Canonical name for the Debug module from elm/core.
-}
debug : Canonical
debug =
    Canonical Pkg.core Name.debug



-- ====== HTML ======


{-| Canonical name for the VirtualDom module from elm/virtual-dom.
-}
virtualDom : Canonical
virtualDom =
    Canonical Pkg.virtualDom Name.virtualDom



-- ====== JSON ======


{-| Canonical name for the Json.Decode module from elm/json.
-}
jsonDecode : Canonical
jsonDecode =
    Canonical Pkg.json "Json.Decode"


{-| Canonical name for the Json.Encode module from elm/json.
-}
jsonEncode : Canonical
jsonEncode =
    Canonical Pkg.json "Json.Encode"



-- ====== BYTES ======


{-| Canonical name for the Bytes module from elm/bytes.
-}
bytes : Canonical
bytes =
    Canonical Pkg.bytes "Bytes"



-- ====== WEBGL ======


{-| Canonical name for the WebGL module from elm-explorations/webgl.
-}
webgl : Canonical
webgl =
    Canonical Pkg.webgl "WebGL"


{-| Canonical name for the WebGL.Texture module from elm-explorations/webgl.
-}
texture : Canonical
texture =
    Canonical Pkg.webgl "WebGL.Texture"


{-| Canonical name for the Math.Vector2 module from elm-explorations/linear-algebra.
-}
vector2 : Canonical
vector2 =
    Canonical Pkg.linearAlgebra "Math.Vector2"


{-| Canonical name for the Math.Vector3 module from elm-explorations/linear-algebra.
-}
vector3 : Canonical
vector3 =
    Canonical Pkg.linearAlgebra "Math.Vector3"


{-| Canonical name for the Math.Vector4 module from elm-explorations/linear-algebra.
-}
vector4 : Canonical
vector4 =
    Canonical Pkg.linearAlgebra "Math.Vector4"


{-| Canonical name for the Math.Matrix4 module from elm-explorations/linear-algebra.
-}
matrix4 : Canonical
matrix4 =
    Canonical Pkg.linearAlgebra "Math.Matrix4"



-- ====== ENCODERS and DECODERS ======


{-| Encode a canonical module name to binary format, including package name and module name.
-}
canonicalEncoder : Canonical -> Bytes.Encode.Encoder
canonicalEncoder (Canonical pkgName name) =
    Bytes.Encode.sequence
        [ Pkg.nameEncoder pkgName
        , BE.string name
        ]


{-| Decode a canonical module name from binary format, including package name and module name.
-}
canonicalDecoder : Bytes.Decode.Decoder Canonical
canonicalDecoder =
    Bytes.Decode.map2 Canonical
        Pkg.nameDecoder
        BD.string


{-| Encode a raw module name to binary format as a string.
-}
rawEncoder : Raw -> Bytes.Encode.Encoder
rawEncoder =
    BE.string


{-| Decode a raw module name from binary format as a string.
-}
rawDecoder : Bytes.Decode.Decoder Raw
rawDecoder =
    BD.string
