module Compiler.Reporting.Error.Import exposing
    ( Error(..), ErrorProps, Problem(..)
    , toReport
    , errorEncoder, errorDecoder, problemEncoder, problemDecoder
    )

{-| Error reporting for module import problems.

This module handles errors that occur when importing modules, including
missing modules, ambiguous imports, and name conflicts.


# Errors

@docs Error, ErrorProps, Problem


# Reporting

@docs toReport


# Serialization

@docs errorEncoder, errorDecoder, problemEncoder, problemDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Doc as D
import Compiler.Reporting.Render.Code as Code
import Compiler.Reporting.Report as Report
import Compiler.Reporting.Suggest as Suggest
import Data.Map as Dict
import Data.Set as EverySet exposing (EverySet)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- ERROR


{-| Represents an import error with location and problem details.
-}
type Error
    = Error ErrorProps


{-| Properties that describe an import error, including location, module name, and the specific problem.
-}
type alias ErrorProps =
    { region : A.Region
    , name : ModuleName.Raw
    , unimportedModules : EverySet String ModuleName.Raw
    , problem : Problem
    }


{-| Specific import problems: module not found or ambiguous due to multiple definitions.
-}
type Problem
    = NotFound
    | Ambiguous String (List String) Pkg.Name (List Pkg.Name)
    | AmbiguousLocal String String (List String)
    | AmbiguousForeign Pkg.Name Pkg.Name (List Pkg.Name)



-- TO REPORT


{-| Convert an import error into a user-friendly error report with suggestions
for fixing module not found, ambiguous imports, or name conflict issues.
-}
toReport : Code.Source -> Error -> Report.Report
toReport source (Error { region, name, unimportedModules, problem }) =
    case problem of
        NotFound ->
            Report.report "MODULE NOT FOUND" region [] <|
                Code.toSnippet source
                    region
                    Nothing
                    ( D.reflow
                        ("You are trying to import a `" ++ name ++ "` module:")
                    , D.stack
                        [ D.reflow
                            "I checked the \"dependencies\" and \"source-directories\" listed in your elm.json, but I cannot find it! Maybe it is a typo for one of these names?"
                        , List.map D.fromName (toSuggestions name unimportedModules) |> D.vcat |> D.indent 4 |> D.dullyellow
                        , case Dict.get identity name Pkg.suggestions of
                            Nothing ->
                                D.toSimpleHint
                                    "If it is not a typo, check the \"dependencies\" and \"source-directories\" of your elm.json to make sure all the packages you need are listed there!"

                            Just dependency ->
                                D.toFancyHint
                                    [ D.fromChars "Maybe"
                                    , D.fromChars "you"
                                    , D.fromChars "want"
                                    , D.fromChars "the"
                                    , D.fromChars "`"
                                        |> D.a (D.fromName name)
                                        |> D.a (D.fromChars "`")
                                    , D.fromChars "module"
                                    , D.fromChars "defined"
                                    , D.fromChars "in"
                                    , D.fromChars "the"
                                    , D.fromChars (Pkg.toChars dependency)
                                    , D.fromChars "package?"
                                    , D.fromChars "Running"
                                    , D.green (D.fromChars ("elm install " ++ Pkg.toChars dependency))
                                    , D.fromChars "should"
                                    , D.fromChars "make"
                                    , D.fromChars "it"
                                    , D.fromChars "available!"
                                    ]
                        ]
                    )

        Ambiguous path _ pkg _ ->
            Report.report "AMBIGUOUS IMPORT" region [] <|
                Code.toSnippet source
                    region
                    Nothing
                    ( D.reflow
                        ("You are trying to import a `" ++ name ++ "` module:")
                    , D.stack
                        [ D.fillSep
                            [ D.fromChars "But"
                            , D.fromChars "I"
                            , D.fromChars "found"
                            , D.fromChars "multiple"
                            , D.fromChars "modules"
                            , D.fromChars "with"
                            , D.fromChars "that"
                            , D.fromChars "name."
                            , D.fromChars "One"
                            , D.fromChars "in"
                            , D.fromChars "the"
                            , D.dullyellow (D.fromChars (Pkg.toChars pkg))
                            , D.fromChars "package,"
                            , D.fromChars "and"
                            , D.fromChars "another"
                            , D.fromChars "defined"
                            , D.fromChars "locally"
                            , D.fromChars "in"
                            , D.fromChars "the"
                            , D.dullyellow (D.fromChars path)
                            , D.fromChars "file."
                            , D.fromChars "I"
                            , D.fromChars "do"
                            , D.fromChars "not"
                            , D.fromChars "have"
                            , D.fromChars "a"
                            , D.fromChars "way"
                            , D.fromChars "to"
                            , D.fromChars "choose"
                            , D.fromChars "between"
                            , D.fromChars "them."
                            ]
                        , D.reflow
                            "Try changing the name of the locally defined module to clear up the ambiguity?"
                        ]
                    )

        AmbiguousLocal path1 path2 paths ->
            Report.report "AMBIGUOUS IMPORT" region [] <|
                Code.toSnippet source
                    region
                    Nothing
                    ( D.reflow
                        ("You are trying to import a `" ++ name ++ "` module:")
                    , D.stack
                        [ D.reflow
                            "But I found multiple files in your \"source-directories\" with that name:"
                        , List.map D.fromChars (path1 :: path2 :: paths) |> D.vcat |> D.indent 4 |> D.dullyellow
                        , D.reflow
                            "Change the module names to be distinct!"
                        ]
                    )

        AmbiguousForeign pkg1 pkg2 pkgs ->
            Report.report "AMBIGUOUS IMPORT" region [] <|
                Code.toSnippet source
                    region
                    Nothing
                    ( D.reflow
                        ("You are trying to import a `" ++ name ++ "` module:")
                    , D.stack
                        [ D.reflow
                            "But multiple packages in your \"dependencies\" that expose a module that name:"
                        , List.map (D.fromChars << Pkg.toChars) (pkg1 :: pkg2 :: pkgs) |> D.vcat |> D.indent 4 |> D.dullyellow
                        , D.reflow <|
                            "There is no way to disambiguate in cases like this right now. Of the known name clashes, "
                                ++ "they are usually for packages with similar purposes, so the current recommendation is to pick just one of them."
                        , D.toSimpleNote <|
                            "It seems possible to resolve this with new syntax in imports, but that is more complicated than it sounds. "
                                ++ "Right now, our module names are tied to GitHub repos, but we may want to get rid of that dependency "
                                ++ "for a variety of reasons. That would in turn have implications for our package infrastructure, "
                                ++ "hosting costs, and possibly on how package names are specified. The particular syntax chosen "
                                ++ "seems like it would interact with all these factors in ways that are difficult to predict, "
                                ++ "potentially leading to harder problems later on. So more design work and planning is needed on these topics."
                        ]
                    )


toSuggestions : ModuleName.Raw -> EverySet String ModuleName.Raw -> List ModuleName.Raw
toSuggestions name unimportedModules =
    Suggest.sort name identity (EverySet.toList compare unimportedModules) |> List.take 4



-- ENCODERS and DECODERS


{-| Serialize an import problem to bytes.
-}
problemEncoder : Problem -> Bytes.Encode.Encoder
problemEncoder problem =
    case problem of
        NotFound ->
            Bytes.Encode.unsignedInt8 0

        Ambiguous path paths pkg pkgs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.string path
                , BE.list BE.string paths
                , Pkg.nameEncoder pkg
                , BE.list Pkg.nameEncoder pkgs
                ]

        AmbiguousLocal path1 path2 paths ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , BE.string path1
                , BE.string path2
                , BE.list BE.string paths
                ]

        AmbiguousForeign pkg1 pkg2 pkgs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , Pkg.nameEncoder pkg1
                , Pkg.nameEncoder pkg2
                , BE.list Pkg.nameEncoder pkgs
                ]


{-| Deserialize an import problem from bytes.
-}
problemDecoder : Bytes.Decode.Decoder Problem
problemDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed NotFound

                    1 ->
                        Bytes.Decode.map4 Ambiguous
                            BD.string
                            (BD.list BD.string)
                            Pkg.nameDecoder
                            (BD.list Pkg.nameDecoder)

                    2 ->
                        Bytes.Decode.map3 AmbiguousLocal
                            BD.string
                            BD.string
                            (BD.list BD.string)

                    3 ->
                        Bytes.Decode.map3 AmbiguousForeign
                            Pkg.nameDecoder
                            Pkg.nameDecoder
                            (BD.list Pkg.nameDecoder)

                    _ ->
                        Bytes.Decode.fail
            )


{-| Serialize an import error to bytes for caching or transmission.
-}
errorEncoder : Error -> Bytes.Encode.Encoder
errorEncoder (Error { region, name, unimportedModules, problem }) =
    Bytes.Encode.sequence
        [ A.regionEncoder region
        , ModuleName.rawEncoder name
        , BE.everySet compare ModuleName.rawEncoder unimportedModules
        , problemEncoder problem
        ]


{-| Deserialize an import error from bytes.
-}
errorDecoder : Bytes.Decode.Decoder Error
errorDecoder =
    Bytes.Decode.map4
        (\region name unimportedModules problem ->
            Error
                { region = region
                , name = name
                , unimportedModules = unimportedModules
                , problem = problem
                }
        )
        A.regionDecoder
        ModuleName.rawDecoder
        (BD.everySet identity ModuleName.rawDecoder)
        problemDecoder
