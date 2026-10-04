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
    , canonicalEncoderS, canonicalDecoderS
    , collectStringsFromCanonical
    , Canonical(..)
    )

{-| A module is known by two names, and this module defines both.

A _raw_ module name is the name as Elm source writes it: upper-case
identifiers joined by dots, such as `Dict` or `Html.Attributes`, with
identifiers as `Compiler.Parse.Variable` defines them. A raw name does not say
which package the module comes from, and two packages may each have a module
with the same raw name. A _canonical_ module name pairs the raw name with the
package the module belongs to, such as `List` in `elm/core`, and so tells
those modules apart.

The rest of the file serves the two types: turning a raw name into a path,
reading and writing raw names as JSON and either kind as binary, ordering
canonical names, and constants naming particular modules of `elm/core`,
`elm/virtual-dom`, `elm/json`, `elm/bytes`, `elm-explorations/webgl` and
`elm-explorations/linear-algebra`.


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


# String-Interned Binary Encoding/Decoding

@docs canonicalEncoderS, canonicalDecoderS
@docs collectStringsFromCanonical
@docs Canonical

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.AST.StringTable as StringTable exposing (StringTable)
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.Package as Pkg
import Compiler.Json.Decode as D
import Compiler.Json.Encode as E
import Compiler.Parse.Primitives as P
import Compiler.Parse.Variable as Var
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- ====== RAW ======


{-| A module name as written in Elm source, such as `Html.Attributes`.

This is a name for `Name`, which is a `String`, not a new type. Any string is
accepted where a `Raw` is expected; of this module's exposed values, only
`decoder` checks that it is a valid module name.

-}
type alias Raw =
    Name


{-| The full name of a module: the package it belongs to and its raw name
within that package, such as `List` in `elm/core`.

The package is a `Compiler.Elm.Package.Name`, author then project. The
constructor is exposed and checks nothing, so any strings make a `Canonical`.

-}
type Canonical
    = Canonical ( String, String ) String


{-| Returns `name` with every dot replaced by `/`, so `Html.Attributes` gives
`Html/Attributes`. The separator is `/` whatever the platform, and no file
extension is added.
-}
toFilePath : Raw -> String
toFilePath name =
    String.map
        (\c ->
            if c == '.' then
                '/'

            else
                c
        )
        name


{-| Returns `name` with every dot replaced by `-`, so `Html.Attributes` gives
`Html-Attributes`.
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


{-| Encodes a raw name as a JSON string.
-}
encode : Raw -> E.Value
encode =
    E.string


{-| A decoder for a JSON string holding a valid raw module name.

The whole text between the quotes, with escape sequences not decoded, must be
upper-case identifiers joined by single dots, and must take fewer than 256
units of position as `Compiler.Parse.Primitives` counts them. When the text is
not a valid name, the error is the row and column, in the whole file, where
reading stopped.

-}
decoder : D.Decoder ( Int, Int ) Raw
decoder =
    D.customString parser Tuple.pair



-- ====== PARSER ======


{-| A parser for a raw module name at the current position, giving its text.

It reads upper-case identifiers joined by dots, and stops before the first
character that can neither continue an identifier nor be a dot. It fails, with
the row and column where reading stopped, in three cases: there is no
upper-case identifier at the start, which is reported as consuming nothing; a
dot is not followed by one; or the name takes 256 or more units of position.
The last two are reported as having consumed input.

-}
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


{-| Reads the upper-case identifier that must begin at `pos`, and the rest of
the name after it with `chompInner`.

Returns whether the name read is valid, with the position and column reached.
With no upper-case character at `pos` the result is `( False, pos, col )`.

-}
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


{-| Reads the rest of a module name from `pos`, which follows at least one
character of an identifier.

Inner characters continue the identifier, and a dot hands over to
`chompStart` for the next one, whose result is returned. Otherwise the result
is `True` with the position and column of the first character that is neither,
or of `end`.

-}
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
                Var.getInnerWidthHelp src pos word
        in
        if width == 0 then
            if word == '.' then
                chompStart src (pos + 1) end (col + 1)

            else
                ( True, pos, col )

        else
            chompInner src (pos + width) end (col + 1)



-- ====== INSTANCES ======


{-| Returns the order of two canonical names: by raw module name, and where
those are equal by package, as `Compiler.Elm.Package.compareName` orders
packages.

This is not the order of the strings `toComparableCanonical` makes, which
begin with the package's author.

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


{-| Returns a canonical name as one string, `author/project:Module`, such as
`elm/core:List`, for use where a `comparable` is needed.

Two different names give different strings as long as no part contains `/` or
`:`. The strings begin with the author, so they do not sort in the order
`compareCanonical` gives.

-}
toComparableCanonical : Canonical -> String
toComparableCanonical (Canonical ( author, project ) name) =
    author ++ "/" ++ project ++ ":" ++ name



-- ====== CORE ======


{-| The canonical name of `Basics` in `elm/core`.
-}
basics : Canonical
basics =
    Canonical Pkg.core Name.basics


{-| The canonical name of `Char` in `elm/core`.
-}
char : Canonical
char =
    Canonical Pkg.core Name.char


{-| The canonical name of `String` in `elm/core`.
-}
string : Canonical
string =
    Canonical Pkg.core Name.string


{-| The canonical name of `Maybe` in `elm/core`.
-}
maybe : Canonical
maybe =
    Canonical Pkg.core Name.maybe


{-| The canonical name of `Result` in `elm/core`.
-}
result : Canonical
result =
    Canonical Pkg.core Name.result


{-| The canonical name of `List` in `elm/core`.
-}
list : Canonical
list =
    Canonical Pkg.core Name.list


{-| The canonical name of `Array` in `elm/core`.
-}
array : Canonical
array =
    Canonical Pkg.core Name.array


{-| The canonical name of `Dict` in `elm/core`.
-}
dict : Canonical
dict =
    Canonical Pkg.core Name.dict


{-| The canonical name of `Tuple` in `elm/core`.
-}
tuple : Canonical
tuple =
    Canonical Pkg.core Name.tuple


{-| The canonical name of `Platform` in `elm/core`.
-}
platform : Canonical
platform =
    Canonical Pkg.core Name.platform


{-| The canonical name of `Platform.Cmd` in `elm/core`.
-}
cmd : Canonical
cmd =
    Canonical Pkg.core "Platform.Cmd"


{-| The canonical name of `Platform.Sub` in `elm/core`.
-}
sub : Canonical
sub =
    Canonical Pkg.core "Platform.Sub"


{-| The canonical name of `Debug` in `elm/core`.
-}
debug : Canonical
debug =
    Canonical Pkg.core Name.debug



-- ====== HTML ======


{-| The canonical name of `VirtualDom` in `elm/virtual-dom`.
-}
virtualDom : Canonical
virtualDom =
    Canonical Pkg.virtualDom Name.virtualDom



-- ====== JSON ======


{-| The canonical name of `Json.Decode` in `elm/json`.
-}
jsonDecode : Canonical
jsonDecode =
    Canonical Pkg.json "Json.Decode"


{-| The canonical name of `Json.Encode` in `elm/json`.
-}
jsonEncode : Canonical
jsonEncode =
    Canonical Pkg.json "Json.Encode"



-- ====== BYTES ======


{-| The canonical name of `Bytes` in `elm/bytes`.
-}
bytes : Canonical
bytes =
    Canonical Pkg.bytes "Bytes"



-- ====== WEBGL ======


{-| The canonical name of `WebGL` in `elm-explorations/webgl`.
-}
webgl : Canonical
webgl =
    Canonical Pkg.webgl "WebGL"


{-| The canonical name of `WebGL.Texture` in `elm-explorations/webgl`.
-}
texture : Canonical
texture =
    Canonical Pkg.webgl "WebGL.Texture"


{-| The canonical name of `Math.Vector2` in `elm-explorations/linear-algebra`.
-}
vector2 : Canonical
vector2 =
    Canonical Pkg.linearAlgebra "Math.Vector2"


{-| The canonical name of `Math.Vector3` in `elm-explorations/linear-algebra`.
-}
vector3 : Canonical
vector3 =
    Canonical Pkg.linearAlgebra "Math.Vector3"


{-| The canonical name of `Math.Vector4` in `elm-explorations/linear-algebra`.
-}
vector4 : Canonical
vector4 =
    Canonical Pkg.linearAlgebra "Math.Vector4"


{-| The canonical name of `Math.Matrix4` in `elm-explorations/linear-algebra`.
-}
matrix4 : Canonical
matrix4 =
    Canonical Pkg.linearAlgebra "Math.Matrix4"



-- ====== ENCODERS and DECODERS ======


{-| Encodes a canonical name as its author, project and module name, each
written inline as `Utils.Bytes.Encode.string` writes a string.
-}
canonicalEncoder : Canonical -> Bytes.Encode.Encoder
canonicalEncoder =
    canonicalEncoderS StringTable.disabled


{-| A decoder for a canonical name written by `canonicalEncoder`.
-}
canonicalDecoder : Bytes.Decode.Decoder Canonical
canonicalDecoder =
    canonicalDecoderS StringTable.disabled


{-| Encodes a raw name as `Utils.Bytes.Encode.string` writes a string.
-}
rawEncoder : Raw -> Bytes.Encode.Encoder
rawEncoder =
    BE.string


{-| A decoder for a raw name written by `rawEncoder`.
-}
rawDecoder : Bytes.Decode.Decoder Raw
rawDecoder =
    BD.string


{-| Encodes a canonical name as its package, as
`Compiler.Elm.Package.nameEncoderS` writes it, followed by its module name,
each string written through `st` as `StringTable.string` writes it.

Every string must be in `st`, unless its index width is 0, as
`StringTable.disabled`'s is; what happens to a missing one is described in
`Compiler.AST.StringTable`.

`collectStringsFromCanonical` gives a collector the strings this writes.

-}
canonicalEncoderS : StringTable -> Canonical -> Bytes.Encode.Encoder
canonicalEncoderS st (Canonical pkgName name) =
    Bytes.Encode.sequence
        [ Pkg.nameEncoderS st pkgName
        , StringTable.string st name
        ]


{-| Produces a decoder for a canonical name written by `canonicalEncoderS`
with the same table.
-}
canonicalDecoderS : StringTable -> Bytes.Decode.Decoder Canonical
canonicalDecoderS st =
    Bytes.Decode.map2 Canonical
        (Pkg.nameDecoderS st)
        (StringTable.stringDec st)


{-| Returns the collector `acc` after giving it the author, the project and the
module name of a canonical name. It keeps each as its own rule decides.
-}
collectStringsFromCanonical : Canonical -> StringTable.Collector -> StringTable.Collector
collectStringsFromCanonical (Canonical pkgName name) acc =
    acc
        |> Pkg.collectStringsFromName pkgName
        |> StringTable.add name
