module Compiler.Elm.Package exposing
    ( Name, Author, Project
    , compareName, toString, toChars, toUrl, toJsonString
    , isKernel
    , dummyName, kernel, ecoKernel, isKernelPackage, core, browser, virtualDom, html, json, bytes, random, time, webgl, linearAlgebra, test
    , suggestions, nearbyNames
    , encode, decoder, keyDecoder
    , nameEncoder, nameDecoder, parser
    )

{-| Utilities for working with Elm package names.

This module handles package names in the form "author/project", providing parsers,
encoders, comparison functions, and constants for common Elm packages. It also includes
support for suggesting packages based on module names and finding nearby package names
using Levenshtein distance.


# Types

@docs Name, Author, Project


# Comparison and Conversion

@docs compareName, toString, toChars, toUrl, toJsonString


# Package Properties

@docs isKernel


# Common Packages

@docs dummyName, kernel, ecoKernel, isKernelPackage, core, browser, virtualDom, html, json, bytes, random, time, webgl, linearAlgebra, test


# Package Suggestions

@docs suggestions, nearbyNames


# JSON Encoding/Decoding

@docs encode, decoder, keyDecoder


# Binary Encoding/Decoding

@docs nameEncoder, nameDecoder, parser

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.Json.Decode as D
import Compiler.Json.Encode as E
import Compiler.Parse.Primitives as P exposing (Col, Row)
import Dict exposing (Dict)
import Levenshtein
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- ====== PACKAGE NAMES ======


{-| Represents a package name in the form of (Author, Project).
This has been simplified from `Name Author Project` as part of the work for
`System.TypeCheck.IO`.
-}
type alias Name =
    ( Author, Project )


{-| Convert a package name to its string representation in the form "author/project".
-}
toString : Name -> String
toString ( author, project ) =
    author ++ "/" ++ project


{-| Compare two package names lexicographically, first by author then by project.
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


{-| Represents the author portion of a package name (e.g., "elm" in "elm/core").
-}
type alias Author =
    String


{-| Represents the project portion of a package name (e.g., "core" in "elm/core").
-}
type alias Project =
    String



-- ====== HELPERS ======


{-| Check if a package is a kernel package (authored by "elm" or "elm-explorations").
-}
isKernel : Name -> Bool
isKernel ( author, _ ) =
    author == elm || author == elmExplorations || author == eco


{-| Convert a package name to a character string in the form "author/project".
-}
toChars : Name -> String
toChars ( author, project ) =
    author ++ "/" ++ project


{-| Convert a package name to a URL-friendly string in the form "author/project".
-}
toUrl : Name -> String
toUrl ( author, project ) =
    author ++ "/" ++ project


{-| Convert a package name to a JSON-compatible string in the form "author/project".
-}
toJsonString : Name -> String
toJsonString ( author, project ) =
    String.join "/" [ author, project ]



-- ====== COMMON PACKAGE NAMES ======


toName : Author -> Project -> Name
toName =
    Tuple.pair


{-| A dummy package name used as a placeholder ("author/project").
-}
dummyName : Name
dummyName =
    toName "author" "project"


{-| The "elm/kernel" package name.
-}
kernel : Name
kernel =
    toName elm "kernel"


{-| The "eco/kernel" package name.
-}
ecoKernel : Name
ecoKernel =
    toName eco "kernel"


{-| Check whether a package is a kernel package (elm/kernel or eco/kernel).
-}
isKernelPackage : Name -> Bool
isKernelPackage pkg =
    pkg == kernel || pkg == ecoKernel


{-| The "elm/core" package name.
-}
core : Name
core =
    toName elm "core"


{-| The "elm/browser" package name.
-}
browser : Name
browser =
    toName elm "browser"


{-| The "elm/virtual-dom" package name.
-}
virtualDom : Name
virtualDom =
    toName elm "virtual-dom"


{-| The "elm/html" package name.
-}
html : Name
html =
    toName elm "html"


{-| The "elm/json" package name.
-}
json : Name
json =
    toName elm "json"


{-| The "elm/bytes" package name.
-}
bytes : Name
bytes =
    toName elm "bytes"


http : Name
http =
    toName elm "http"


{-| The "elm/random" package name.
-}
random : Name
random =
    toName elm "random"


{-| The "elm/time" package name.
-}
time : Name
time =
    toName elm "time"


url : Name
url =
    toName elm "url"


{-| The "elm-explorations/webgl" package name.
-}
webgl : Name
webgl =
    toName elmExplorations "webgl"


{-| The "elm-explorations/linear-algebra" package name.
-}
linearAlgebra : Name
linearAlgebra =
    toName elmExplorations "linear-algebra"


{-| The "elm-explorations/test" package name.
-}
test : Name
test =
    toName elmExplorations "test"


elm : Author
elm =
    "elm"


elmExplorations : Author
elmExplorations =
    "elm-explorations"


eco : String
eco =
    "eco"



-- ====== PACKAGE SUGGESTIONS ======


{-| A dictionary mapping common module names to the packages that contain them.
Used to suggest which package to install when a module is missing.
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


{-| Find up to 4 package names from the given list that are most similar to the target name.
Uses Levenshtein distance to measure similarity, with special handling for "elm" and
"elm-explorations" authors (treated as distance 0).
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


authorDistance : String -> Author -> Int
authorDistance given possibility =
    if possibility == elm || possibility == elmExplorations then
        0

    else
        abs (Levenshtein.distance given possibility)


projectDistance : String -> Project -> Int
projectDistance given possibility =
    abs (Levenshtein.distance given possibility)



-- ====== JSON ======


{-| JSON decoder for package names. Expects a string in "author/project" format.
-}
decoder : D.Decoder ( Row, Col ) Name
decoder =
    D.customString parser Tuple.pair


{-| Encode a package name as a JSON string value.
-}
encode : Name -> E.Value
encode name =
    E.string (toChars name)


{-| JSON key decoder for package names used in JSON objects.
Accepts a function to create error values from row and column positions.
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


{-| Parser for package names in "author/project" format.
Enforces naming rules: author starts with alphanumeric, project starts with lowercase,
both can contain dashes (but not consecutive), and must be under 256 characters.
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


isLowerOrDigit : Char -> Bool
isLowerOrDigit word =
    Char.isLower word || Char.isDigit word


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


{-| Binary encoder for package names. Encodes author and project as consecutive strings.
-}
nameEncoder : Name -> Bytes.Encode.Encoder
nameEncoder ( author, project ) =
    Bytes.Encode.sequence
        [ BE.string author
        , BE.string project
        ]


{-| Binary decoder for package names. Decodes two consecutive strings as (author, project).
-}
nameDecoder : Bytes.Decode.Decoder Name
nameDecoder =
    Bytes.Decode.map2 Tuple.pair BD.string BD.string
