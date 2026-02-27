module Terminal.Terminal.Helpers exposing
    ( version, parseVersion
    , elmFile, parseElmFile, filePath, parseFilePath
    , package, parsePackage
    )

{-| Command-line argument parsers and validators for terminal commands.

This module provides parsers for common command-line argument types including
version numbers, package names, and file paths. Each parser includes validation,
suggestions, and example generation for user feedback.


# Version Parsing

@docs version, parseVersion


# File Path Parsing

@docs elmFile, parseElmFile, filePath, parseFilePath


# Package Parsing

@docs package, parsePackage

-}

import Builder.Deps.Registry as Registry
import Builder.Stuff as Stuff
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V
import Compiler.Parse.Primitives as P
import Compiler.Reporting.Suggest as Suggest
import Data.Map as Dict
import Task exposing (Task)
import Terminal.Terminal.Internal exposing (Parser(..))
import System.IO exposing (FilePath)
import Utils.Main as Utils



-- ====== VERSION ======


{-| Parser for version numbers.

Accepts semantic version strings like "1.0.0" or "2.3.4".

-}
version : Parser
version =
    Parser
        { singular = "version"
        , plural = "versions"
        , suggest = suggestVersion
        , examples = exampleVersions >> Task.succeed
        }


{-| Parse a string as a version number.

Returns Just the parsed version or Nothing if invalid.

-}
parseVersion : String -> Maybe V.Version
parseVersion chars =
    case P.fromByteString V.parser Tuple.pair chars of
        Ok vsn ->
            Just vsn

        Err _ ->
            Nothing


suggestVersion : String -> Task Never (List String)
suggestVersion _ =
    Task.succeed []


exampleVersions : String -> List String
exampleVersions chars =
    let
        chunks : List String
        chunks =
            String.split "." chars

        isNumber : String -> Bool
        isNumber cs =
            not (String.isEmpty cs) && String.all Char.isDigit cs
    in
    if List.all isNumber chunks then
        case chunks of
            [ x ] ->
                [ x ++ ".0.0" ]

            [ x, y ] ->
                [ x ++ "." ++ y ++ ".0" ]

            x :: y :: z :: _ ->
                [ x ++ "." ++ y ++ "." ++ z ]

            _ ->
                [ "1.0.0", "2.0.3" ]

    else
        [ "1.0.0", "2.0.3" ]



-- ====== ELM FILE ======


{-| Parser for Elm source file paths.

Accepts file paths ending in .elm extension.

-}
elmFile : Parser
elmFile =
    Parser
        { singular = "elm file"
        , plural = "elm files"
        , suggest = \_ -> Task.succeed []
        , examples = exampleElmFiles
        }


{-| Parse a string as an Elm file path.

Returns Just the file path if it has an .elm extension, Nothing otherwise.

-}
parseElmFile : String -> Maybe FilePath
parseElmFile chars =
    if Utils.fpTakeExtension chars == ".elm" then
        Just chars

    else
        Nothing


exampleElmFiles : String -> Task Never (List String)
exampleElmFiles _ =
    Task.succeed [ "Main.elm", "src/Main.elm" ]



-- ====== FILE PATH ======


{-| Parser for general file paths.

Accepts any string as a file path without validation.

-}
filePath : Parser
filePath =
    Parser
        { singular = "file path"
        , plural = "file paths"
        , suggest = \_ -> Task.succeed []
        , examples = exampleFilePaths
        }


{-| Parse a string as a file path.

Always succeeds, accepting any string as a valid file path.

-}
parseFilePath : String -> Maybe FilePath
parseFilePath =
    Just


exampleFilePaths : String -> Task Never (List String)
exampleFilePaths _ =
    Task.succeed [ "Main.elm", "src" ]



-- ====== PACKAGE ======


{-| Parser for Elm package names.

Accepts package names in the format "author/project" like "elm/core" or "elm/html".

-}
package : Parser
package =
    Parser
        { singular = "package"
        , plural = "packages"
        , suggest = suggestPackages
        , examples = examplePackages
        }


{-| Parse a string as an Elm package name.

Returns Just the package name if valid (format: author/project), Nothing otherwise.

-}
parsePackage : String -> Maybe Pkg.Name
parsePackage chars =
    case P.fromByteString Pkg.parser Tuple.pair chars of
        Ok pkg ->
            Just pkg

        Err _ ->
            Nothing


suggestPackages : String -> Task Never (List String)
suggestPackages given =
    Stuff.getPackageCache
        |> Task.andThen
            (\cache ->
                Registry.read cache
                    |> Task.map
                        (\maybeRegistry ->
                            case maybeRegistry of
                                Nothing ->
                                    []

                                Just (Registry.Registry _ versions) ->
                                    List.map Pkg.toChars (Dict.keys compare versions) |> List.filter (String.startsWith given)
                        )
            )


examplePackages : String -> Task Never (List String)
examplePackages given =
    Stuff.getPackageCache
        |> Task.andThen
            (\cache ->
                Registry.read cache
                    |> Task.map
                        (\maybeRegistry ->
                            case maybeRegistry of
                                Nothing ->
                                    [ "elm/json"
                                    , "elm/http"
                                    , "elm/random"
                                    ]

                                Just (Registry.Registry _ versions) ->
                                    Suggest.sort given Pkg.toChars (Dict.keys compare versions) |> List.take 4 |> List.map Pkg.toChars
                        )
            )
