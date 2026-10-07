module Compiler.Elm.Package exposing
    ( Name, Author, Project
    , compareName, toString, toChars, toUrl, toJsonString
    , isKernel
    , dummyName, kernel, ecoKernel, ecoSystem, core, virtualDom, html, json, bytes, webgl, linearAlgebra
    , suggestions, nearbyNames
    , encode, decoder, keyDecoder
    , nameEncoder, nameDecoder, parser
    , nameEncoderS, nameDecoderS, collectStringsFromName
    )

{-| An Elm package is identified by a name in two parts, its author and its
project, written `author/project` as in `elm/core`. This module is that name:
how it is held, how it is read from text and written back, and the names the
compiler refers to by itself.

A `Name` is a pair of two plain strings, and nothing in the type checks them.
A name is checked only by `parser`, and by `decoder` and `keyDecoder`, which
use it; the binary decoders check nothing. The author starts with an ASCII
letter or digit and continues with letters and digits; the project starts with
a lowercase letter and continues with lowercase letters and digits. Either part
may also contain dashes, but not two in a row nor one that ends the input, and
each part is shorter than 256 characters.

`toString`, `toChars`, `toUrl` and `toJsonString` give the same text,
`author/project`, with nothing escaped. `encode` writes that text as a JSON
string, escaped as `Compiler.Json.Encode.string` escapes it.

A _kernel package_ is one whose author is `elm`, `elm-explorations` or `eco`,
which is what `isKernel` tests. What a kernel package may do that others may
not is decided by the modules that ask.

`suggestions` maps a few commonly imported module names to the package that
provides each, and `nearbyNames` picks, from a list of names, the few closest
to a given one.

The binary codecs write the author and then the project as two strings. The `S`
variants write them through a `StringTable`, as `Compiler.AST.StringTable`
describes; the others write them inline.


# Types

@docs Name, Author, Project


# Comparison and Conversion

@docs compareName, toString, toChars, toUrl, toJsonString


# Package Properties

@docs isKernel


# Common Packages

@docs dummyName, kernel, ecoKernel, ecoSystem, core, virtualDom, html, json, bytes, webgl, linearAlgebra


# Package Suggestions

@docs suggestions, nearbyNames


# JSON Encoding/Decoding

@docs encode, decoder, keyDecoder


# Parsing and Binary Encoding/Decoding

@docs nameEncoder, nameDecoder, parser


# String-Interned Binary Encoding/Decoding

@docs nameEncoderS, nameDecoderS, collectStringsFromName

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.AST.StringTable as StringTable exposing (StringTable)
import Compiler.Json.Decode as D
import Compiler.Json.Encode as E
import Compiler.Parse.Primitives as P exposing (Col, Row)
import Dict exposing (Dict)
import Levenshtein



-- ====== PACKAGE NAMES ======


{-| A package name: its author and its project, as in `elm/core`.

This is a name for a pair of strings, not a new type. Any two strings are
accepted as a `Name`, so a value that did not come from `parser`, `decoder` or
`keyDecoder` need not follow the syntax rules they check.

-}
type alias Name =
    ( Author, Project )


{-| Returns the name as `author/project`.
-}
toString : Name -> String
toString ( author, project ) =
    author ++ "/" ++ project


{-| Returns the order of two names: by author, and by project where the authors
are equal.
-}
compareName : Name -> Name -> Order
compareName ( name1, project1 ) ( name2, project2 ) =
    case compare name1 name2 of
        LT ->
            LT

        EQ ->
            compare project1 project2

        GT ->
            GT


{-| The author part of a package name, the `elm` in `elm/core`.

This is a name for `String`, not a new type, and any string is accepted where
an `Author` is expected.

-}
type alias Author =
    String


{-| The project part of a package name, the `core` in `elm/core`.

This is a name for `String`, not a new type, and any string is accepted where
a `Project` is expected.

-}
type alias Project =
    String



-- ====== HELPERS ======


{-| Returns whether the package is a kernel package, which depends on its
author alone: `elm`, `elm-explorations` or `eco`.
-}
isKernel : Name -> Bool
isKernel ( author, _ ) =
    author == elm || author == elmExplorations || author == eco


{-| Returns the name as `author/project`, the same text as `toString`.
-}
toChars : Name -> String
toChars ( author, project ) =
    author ++ "/" ++ project


{-| Returns the name as `author/project`, the same text as `toString`.

Nothing is escaped for use in a URL. A name that `parser` accepts holds only
letters, digits, dashes and the one `/`, which need no escaping.

-}
toUrl : Name -> String
toUrl ( author, project ) =
    author ++ "/" ++ project


{-| Returns the name as `author/project`, the same text as `toString`. It is
not quoted, so it is the text of a JSON string, not a JSON string literal.
-}
toJsonString : Name -> String
toJsonString ( author, project ) =
    String.join "/" [ author, project ]



-- ====== COMMON PACKAGE NAMES ======


{-| Builds a name from an author and a project.
-}
toName : Author -> Project -> Name
toName =
    Tuple.pair


{-| A placeholder package name, `author/project`.
-}
dummyName : Name
dummyName =
    toName "author" "project"


{-| The package name `elm/kernel`.
-}
kernel : Name
kernel =
    toName elm "kernel"


{-| The package name `eco/kernel`.
-}
ecoKernel : Name
ecoKernel =
    toName eco "kernel"


{-| The package name `eco/system`.
-}
ecoSystem : Name
ecoSystem =
    toName eco "system"


{-| The package name `elm/core`.
-}
core : Name
core =
    toName elm "core"


{-| The package name `elm/browser`.
-}
browser : Name
browser =
    toName elm "browser"


{-| The package name `elm/virtual-dom`.
-}
virtualDom : Name
virtualDom =
    toName elm "virtual-dom"


{-| The package name `elm/html`.
-}
html : Name
html =
    toName elm "html"


{-| The package name `elm/json`.
-}
json : Name
json =
    toName elm "json"


{-| The package name `elm/bytes`.
-}
bytes : Name
bytes =
    toName elm "bytes"


{-| The package name `elm/http`.
-}
http : Name
http =
    toName elm "http"


{-| The package name `elm/random`.
-}
random : Name
random =
    toName elm "random"


{-| The package name `elm/time`.
-}
time : Name
time =
    toName elm "time"


{-| The package name `elm/url`.
-}
url : Name
url =
    toName elm "url"


{-| The package name `elm-explorations/webgl`.
-}
webgl : Name
webgl =
    toName elmExplorations "webgl"


{-| The package name `elm-explorations/linear-algebra`.
-}
linearAlgebra : Name
linearAlgebra =
    toName elmExplorations "linear-algebra"


{-| The author `elm`, one of the three kernel authors that `isKernel` accepts.
-}
elm : Author
elm =
    "elm"


{-| The author `elm-explorations`, one of the three kernel authors that
`isKernel` accepts.
-}
elmExplorations : Author
elmExplorations =
    "elm-explorations"


{-| The author `eco`, one of the three kernel authors that `isKernel` accepts.
-}
eco : String
eco =
    "eco"



-- ====== PACKAGE SUGGESTIONS ======


{-| A table from module name to the package that provides the module, for
fourteen commonly imported modules of `elm/browser`, `elm/file`, `elm/html`,
`elm/http`, `elm/json`, `elm/random`, `elm/time` and `elm/url`.

A module that is not listed has no entry, even when it belongs to one of those
packages, as `Browser.Navigation` does.

-}
suggestions : Dict String Name
suggestions =
    let
        file : Name
        file =
            toName elm "file"
    in
    Dict.fromList
        [ ( "Browser", browser )
        , ( "File", file )
        , ( "File.Download", file )
        , ( "File.Select", file )
        , ( "Html", html )
        , ( "Html.Attributes", html )
        , ( "Html.Events", html )
        , ( "Http", http )
        , ( "Json.Decode", json )
        , ( "Json.Encode", json )
        , ( "Random", random )
        , ( "Time", time )
        , ( "Url.Parser", url )
        , ( "Url", url )
        ]



-- ====== NEARBY NAMES ======


{-| Returns up to four of `possibleNames`, closest to the given name first.

A candidate's distance is the distance between the two authors plus the
distance between the two projects, each as `Levenshtein.distance` gives it.
The exception is a candidate whose author is `elm` or `elm-explorations`: its
author distance is 0 whatever author was given, so its project alone decides.

-}
nearbyNames : Name -> List Name -> List Name
nearbyNames ( author1, project1 ) possibleNames =
    let
        authorDist : Author -> Int
        authorDist =
            authorDistance author1

        projectDist : Project -> Int
        projectDist =
            projectDistance project1

        nameDistance : Name -> Int
        nameDistance ( author2, project2 ) =
            authorDist author2 + projectDist project2
    in
    List.take 4 (List.sortBy nameDistance possibleNames)


{-| Returns how far the author `possibility` is from the author `given`: 0 when
`possibility` is `elm` or `elm-explorations`, and otherwise the
`Levenshtein.distance` between the two.
-}
authorDistance : String -> Author -> Int
authorDistance given possibility =
    if possibility == elm || possibility == elmExplorations then
        0

    else
        abs (Levenshtein.distance given possibility)


{-| Returns the `Levenshtein.distance` between the projects `given` and
`possibility`.
-}
projectDistance : String -> Project -> Int
projectDistance given possibility =
    abs (Levenshtein.distance given possibility)



-- ====== JSON ======


{-| A decoder for a JSON string whose whole text is a package name, read by
`parser`.

A string that is not a name fails with nothing but a position: the row and
column at which reading the name failed, or at which text was left over after
it.

-}
decoder : D.Decoder ( Row, Col ) Name
decoder =
    D.customString parser Tuple.pair


{-| Returns the name as a JSON string holding `author/project`.
-}
encode : Name -> E.Value
encode name =
    E.string (toChars name)


{-| Produces a key decoder that reads each object key as a package name, with
`parser`.

A key that is not a name fails with `toError` given the row and column at which
reading the name failed, or at which text was left over after it.

-}
keyDecoder : (Row -> Col -> x) -> D.KeyDecoder x Name
keyDecoder toError =
    let
        keyParser : P.Parser x Name
        keyParser =
            P.specialize (\( r, c ) _ _ -> toError r c) parser
    in
    D.KeyDecoder keyParser toError



-- ====== PARSER ======


{-| A parser for a package name, `author/project`, whose error is the row and
column at which it failed.

The author starts with an ASCII letter or digit and continues with letters and
digits. The project starts with a lowercase letter and continues with lowercase
letters and digits. Either part may contain dashes, and fails on two in a row
or on a dash that ends the input. A dash just before some other character that
cannot continue the part is kept as its last character, so `elm-/core` reads
with the author `elm-`. Each part must be shorter than 256 characters.

The parser stops at the first character that cannot continue the project and
leaves the rest of the input unread.

-}
parser : P.Parser ( Row, Col ) Name
parser =
    parseName Char.isAlphaNum Char.isAlphaNum
        |> P.andThen
            (\author ->
                P.word1 '/' Tuple.pair
                    |> P.andThen (\_ -> parseName Char.isLower isLowerOrDigit)
                    |> P.map
                        (\project -> ( author, project ))
            )


{-| Produces a parser for one part of a name: a character for which
`isGoodStart` holds, then characters for which `isGoodInner` holds and dashes,
read as `chompName` reads them.

It fails without consuming input when there is no first character or it is not
a good start. It fails having consumed input, at the column where reading
stopped, when `chompName` reports the part malformed or the part is 256
characters or longer.

-}
parseName : (Char -> Bool) -> (Char -> Bool) -> P.Parser ( Row, Col ) String
parseName isGoodStart isGoodInner =
    P.Parser <|
        \(P.State st) ->
            if st.pos >= st.end then
                P.Eerr st.row st.col Tuple.pair

            else
                let
                    word : Char
                    word =
                        P.unsafeIndex st.src st.pos
                in
                if not (isGoodStart word) then
                    P.Eerr st.row st.col Tuple.pair

                else
                    let
                        ( isGood, newPos ) =
                            chompName isGoodInner st.src (st.pos + 1) st.end False

                        len : Int
                        len =
                            newPos - st.pos

                        newCol : Col
                        newCol =
                            st.col + len
                    in
                    if isGood && len < 256 then
                        let
                            newState : P.State
                            newState =
                                P.State { st | pos = newPos, col = newCol }
                        in
                        P.Cok (String.slice st.pos newPos st.src) newState

                    else
                        P.Cerr st.row newCol Tuple.pair


{-| Returns whether `word` is an ASCII lowercase letter or a digit.
-}
isLowerOrDigit : Char -> Bool
isLowerOrDigit word =
    Char.isLower word || Char.isDigit word


{-| Returns whether the rest of a name part in `src`, from `pos`, is well
formed, and the position where the part ends.

It reads characters for which `isGoodChar` holds and dashes, and stops at
`end`, at a second dash in a row, or at any other character. `prevWasDash` says
whether the character before `pos` was a dash. The part is malformed when it
stops at a second dash, which is where it ends, or when a dash is the last
character before `end`. A dash before any other stopping character is accepted.

-}
chompName : (Char -> Bool) -> String -> Int -> Int -> Bool -> ( Bool, Int )
chompName isGoodChar src pos end prevWasDash =
    if pos >= end then
        ( not prevWasDash, pos )

    else
        let
            word : Char
            word =
                P.unsafeIndex src pos
        in
        if isGoodChar word then
            chompName isGoodChar src (pos + 1) end False

        else if word == '-' then
            if prevWasDash then
                ( False, pos )

            else
                chompName isGoodChar src (pos + 1) end True

        else
            ( True, pos )



-- ====== ENCODERS and DECODERS ======


{-| Encodes a name as its author followed by its project, each written inline
as a string, with no string table. It is `nameEncoderS StringTable.disabled`.
-}
nameEncoder : Name -> Bytes.Encode.Encoder
nameEncoder =
    nameEncoderS StringTable.disabled


{-| A decoder for a name written by `nameEncoder`: two inline strings, the
author and then the project.
-}
nameDecoder : Bytes.Decode.Decoder Name
nameDecoder =
    nameDecoderS StringTable.disabled


{-| Encodes a name as its author followed by its project, each written through
`st` as `StringTable.string` writes a string.

Both strings must be in `st`, unless it is `StringTable.disabled`; what happens
to a missing string is described in `Compiler.AST.StringTable`.

-}
nameEncoderS : StringTable -> Name -> Bytes.Encode.Encoder
nameEncoderS st ( author, project ) =
    Bytes.Encode.sequence
        [ StringTable.string st author
        , StringTable.string st project
        ]


{-| Produces a decoder for a name written by `nameEncoderS` with the same
table.
-}
nameDecoderS : StringTable -> Bytes.Decode.Decoder Name
nameDecoderS st =
    Bytes.Decode.map2 Tuple.pair (StringTable.stringDec st) (StringTable.stringDec st)


{-| Returns the collector `acc` after giving it the author and then the project
of a name. It keeps each as its own rule decides.
-}
collectStringsFromName : Name -> StringTable.Collector -> StringTable.Collector
collectStringsFromName ( author, project ) acc =
    acc
        |> StringTable.add author
        |> StringTable.add project
