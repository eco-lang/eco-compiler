module Terminal.Terminal.Helpers exposing
    ( version, parseVersion
    , elmFile, parseElmFile
    , package, parsePackage
    )

{-| Argument kinds that several terminal commands share: a version, an Elm
source file, and a package name.

Each kind comes as two values, because a command-line argument is described and
parsed separately. The `Parser` (from `Terminal.Terminal.Internal`) only
describes the kind: its singular and plural names for help and error messages,
a task suggesting completions for a partial argument, and a task giving example
values. It does not parse. The matching `parseX` function turns an argument
string into a value, or `Nothing`, and a command needs both.

The package kind is the only one whose suggestions and examples look anything
up: they read the package registry already cached on disk, and never contact
the network.


# Version Parsing

@docs version, parseVersion


# Elm File Parsing

@docs elmFile, parseElmFile


# Package Parsing

@docs package, parsePackage

-}

import Builder.Deps.Registry as Registry
import Builder.Stuff as Stuff
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V
import Compiler.Parse.Primitives as P
import Compiler.Reporting.Suggest as Suggest
import Dict
import System.IO exposing (FilePath)
import Task exposing (Task)
import Terminal.Terminal.Internal exposing (Parser(..))
import Utils.Main as Utils



-- ====== VERSION ======


{-| The description of a version argument, such as `1.0.0`.

It suggests nothing. Its examples complete an argument made of one or two
numbers separated by dots to three, so `1.2` gives `1.2.0`; an argument of
three or more numbers gives its first three, and anything else gives `1.0.0`
and `2.0.3`.

-}
version : Parser
version =
    Parser
        { singular = "version"
        , plural = "versions"
        , suggest = suggestVersion
        , examples = exampleVersions >> Task.succeed
        }


{-| Returns the version that the whole of `chars` spells, as
`Compiler.Elm.Version.parser` reads it, or `Nothing` if it is not one.
-}
parseVersion : String -> Maybe V.Version
parseVersion chars =
    case P.fromByteString V.parser Tuple.pair chars of
        Ok vsn ->
            Just vsn

        Err _ ->
            Nothing


{-| Returns no suggestions, whatever has been typed.
-}
suggestVersion : String -> Task Never (List String)
suggestVersion _ =
    Task.succeed []


{-| Returns one example version made from the partial version `chars`, or two
fixed examples when `chars` is not dot-separated numbers.

`chars` with one or two numbers is padded with zeros to three, and `chars` with
more than three numbers is cut to its first three. An empty part, as in `1..2`,
counts as not a number.

-}
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


{-| The description of an Elm source file argument. It suggests nothing, and
its examples are `Main.elm` and `src/Main.elm`.
-}
elmFile : Parser
elmFile =
    Parser
        { singular = "elm file"
        , plural = "elm files"
        , suggest = \_ -> Task.succeed []
        , examples = exampleElmFiles
        }


{-| Returns `chars` unchanged if its extension, as `Utils.Main.fpTakeExtension`
finds it, is exactly `.elm`, and `Nothing` otherwise.

The case must match, so `Main.ELM` is refused. Whether the file exists is not
checked.

-}
parseElmFile : String -> Maybe FilePath
parseElmFile chars =
    if Utils.fpTakeExtension chars == ".elm" then
        Just chars

    else
        Nothing


{-| Returns the two fixed example Elm file paths, ignoring what has been typed.
-}
exampleElmFiles : String -> Task Never (List String)
exampleElmFiles _ =
    Task.succeed [ "Main.elm", "src/Main.elm" ]



-- ====== PACKAGE ======


{-| The description of a package name argument, such as `elm/core`.

Its suggestions are every package name in the cached registry that starts with
what has been typed, and none when no registry is cached. Its examples are up to
four registry names closest to what has been typed, ignoring case, as
`Compiler.Reporting.Suggest.sort` orders them, or `elm/json`, `elm/http` and
`elm/random` when no registry is cached. Both read the registry from the
package cache, whose directory is created if it is missing.

-}
package : Parser
package =
    Parser
        { singular = "package"
        , plural = "packages"
        , suggest = suggestPackages
        , examples = examplePackages
        }


{-| Returns the package name that the whole of `chars` spells, as
`Compiler.Elm.Package.parser` reads it (`author/project`), or `Nothing` if it
is not one.
-}
parsePackage : String -> Maybe Pkg.Name
parsePackage chars =
    case P.fromByteString Pkg.parser Tuple.pair chars of
        Ok pkg ->
            Just pkg

        Err _ ->
            Nothing


{-| Returns every package name in the cached registry that starts with `given`,
case-sensitively, or none when no registry is cached.
-}
suggestPackages : String -> Task Never (List String)
suggestPackages given =
    Stuff.resolveBundledPackages []
        |> Task.andThen Stuff.getPackageCache
        |> Task.andThen
            (\cache ->
                Registry.read cache
                    |> Task.map
                        (\maybeRegistry ->
                            case maybeRegistry of
                                Nothing ->
                                    []

                                Just (Registry.Registry _ versions) ->
                                    List.map Pkg.toChars (Dict.keys versions) |> List.filter (String.startsWith given)
                        )
            )


{-| Returns up to four package names in the cached registry closest to `given`,
ignoring case, or three fixed names when no registry is cached.
-}
examplePackages : String -> Task Never (List String)
examplePackages given =
    Stuff.resolveBundledPackages []
        |> Task.andThen Stuff.getPackageCache
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
                                    Suggest.sort given Pkg.toChars (Dict.keys versions) |> List.take 4 |> List.map Pkg.toChars
                        )
            )
