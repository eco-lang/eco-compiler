module Builder.Reporting.Exit exposing
    ( toStderr, toJson
    , Init(..), initToReport
    , Install(..), installToReport
    , Uninstall(..), uninstallToReport
    , Make(..), makeToReport
    , Repl(..), replToReport
    , Test(..), testToReport
    , Diff(..), diffToReport
    , Bump(..), bumpToReport
    , BuildProblem(..), BuildProjectProblem(..)
    , buildProblemEncoder, buildProblemDecoder
    , buildProjectProblemEncoder, buildProjectProblemDecoder
    , RegistryProblem(..), registryProblemEncoder, registryProblemDecoder
    , Details(..), DetailsBadDep(..), detailsBadDepEncoder, detailsBadDepDecoder
    , Solver(..)
    , Outline(..), OutlineProblem(..)
    , PackageProblem(..)
    , DocsProblem(..)
    , Generate(..)
    )

{-| Exit error reporting for the Elm build tool and package manager.

This module defines all possible error conditions that can occur during
build tool operations (init, install, make, etc.) and provides
functions to convert them into user-friendly error reports.


# Output

@docs toStderr, toJson


# Init Errors

@docs Init, initToReport


# Install Errors

@docs Install, installToReport


# Uninstall Errors

@docs Uninstall, uninstallToReport


# Make Errors

@docs Make, makeToReport


# REPL Errors

@docs Repl, replToReport


# Test Errors

@docs Test, testToReport


# Diff Errors

@docs Diff, diffToReport


# Bump Errors

@docs Bump, bumpToReport


# Build Problems

@docs BuildProblem, BuildProjectProblem
@docs buildProblemEncoder, buildProblemDecoder
@docs buildProjectProblemEncoder, buildProjectProblemDecoder


# Registry Problems

@docs RegistryProblem, registryProblemEncoder, registryProblemDecoder


# Details Problems

@docs Details, DetailsBadDep, detailsBadDepEncoder, detailsBadDepDecoder


# Solver Problems

@docs Solver


# Outline Problems

@docs Outline, OutlineProblem


# Package Problems

@docs PackageProblem


# Documentation Problems

@docs DocsProblem


# Code Generation

@docs Generate

-}

import Builder.File as File
import Builder.Http as Http
import Builder.Reporting.Exit.Help as Help
import Bytes.Decode
import Bytes.Encode
import Compiler.Data.Name as N
import Compiler.Data.NonEmptyList as NE
import Compiler.Elm.Constraint as C
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V
import Compiler.Json.Decode as Decode
import Compiler.Json.Encode as Encode
import Compiler.Parse.Primitives exposing (Col, Row)
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Doc as D
import Compiler.Reporting.Error as Error
import Compiler.Reporting.Error.Import as Import
import Compiler.Reporting.Error.Json as Json
import Compiler.Reporting.Render.Code as Code
import Data.Map as Dict exposing (Dict)
import Task exposing (Task)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Main as Utils exposing (FilePath)



-- ====== RENDERERS ======


{-| Writes a report to stderr with formatted output.
-}
toStderr : Help.Report -> Task Never ()
toStderr report =
    Help.toStderr (Help.reportToDoc report)


{-| Converts a report to JSON format for machine consumption.
-}
toJson : Help.Report -> Encode.Value
toJson report =
    Help.reportToJson report



-- ====== INIT ======


{-| Error conditions that can occur during project initialization.
-}
type Init
    = InitNoSolution (List Pkg.Name)
    | InitNoOfflineSolution (List Pkg.Name)
    | InitSolverProblem Solver
    | InitAlreadyExists
    | InitRegistryProblem RegistryProblem


{-| Converts an initialization error to a user-friendly report.
-}
initToReport : Init -> Help.Report
initToReport exit =
    case exit of
        InitNoSolution pkgs ->
            Help.report "NO SOLUTION"
                Nothing
                "I tried to create an elm.json with the following direct dependencies:"
                [ List.map (D.dullyellow << D.fromChars << Pkg.toChars) pkgs |> D.vcat |> D.indent 4
                , D.reflow <|
                    "I could not find compatible versions though! This should not happen, so please ask around "
                        ++ "one of the community forums at https://elm-lang.org/community to learn what is going on!"
                ]

        InitNoOfflineSolution pkgs ->
            Help.report "NO OFFLINE SOLUTION"
                Nothing
                "I tried to create an elm.json with the following direct dependencies:"
                [ List.map (D.dullyellow << D.fromChars << Pkg.toChars) pkgs |> D.vcat |> D.indent 4
                , D.reflow <|
                    "I could not find compatible versions though, but that may be because I could not connect to "
                        ++ "https://package.elm-lang.org to get the latest list of packages. Are you able to connect to "
                        ++ "the internet? Please ask around one of the community forums at https://elm-lang.org/community for help!"
                ]

        InitSolverProblem solver ->
            toSolverReport solver

        InitAlreadyExists ->
            Help.report "EXISTING PROJECT"
                Nothing
                "You already have an elm.json file, so there is nothing for me to initialize!"
                [ D.fillSep
                    [ D.fromChars "Maybe"
                    , D.green (D.fromChars (D.makeLink "init"))
                    , D.fromChars "can"
                    , D.fromChars "help"
                    , D.fromChars "you"
                    , D.fromChars "figure"
                    , D.fromChars "out"
                    , D.fromChars "what"
                    , D.fromChars "to"
                    , D.fromChars "do"
                    , D.fromChars "next?"
                    ]
                ]

        InitRegistryProblem problem ->
            "I need the list of published packages before I can start initializing projects" |> toRegistryProblemReport "PROBLEM LOADING PACKAGE LIST" problem



-- ====== DIFF ======


{-| Error conditions that can occur when computing package diffs.
-}
type Diff
    = DiffNoOutline
    | DiffBadOutline Outline
    | DiffApplication
    | DiffNoExposed
    | DiffUnpublished
    | DiffUnknownPackage Pkg.Name (List Pkg.Name)
    | DiffUnknownVersion V.Version (List V.Version)
    | DiffDocsProblem V.Version DocsProblem
    | DiffMustHaveLatestRegistry RegistryProblem
    | DiffBadDetails Details
    | DiffBadBuild BuildProblem


{-| Converts a diff error to a user-friendly report.
-}
diffToReport : Diff -> Help.Report
diffToReport diff =
    case diff of
        DiffNoOutline ->
            Help.report "DIFF WHAT?"
                Nothing
                "I cannot find an elm.json so I am not sure what you want me to diff. Normally you run `elm diff` from within a project!"
                [ "If you are just curious to see a diff, try running this command:" |> D.reflow
                , D.fromChars "elm diff elm/http 1.0.0 2.0.0" |> D.green |> D.indent 4
                ]

        DiffBadOutline outline ->
            toOutlineReport outline

        DiffApplication ->
            Help.report "CANNOT DIFF APPLICATIONS"
                (Just "elm.json")
                "Your elm.json says this project is an application, but `elm diff` only works with packages. That way there are previously published versions of the API to diff against!"
                [ "If you are just curious to see a diff, try running this command:" |> D.reflow
                , D.fromChars "elm diff elm/json 1.0.0 1.1.2" |> D.dullyellow |> D.indent 4
                ]

        DiffNoExposed ->
            Help.report "NO EXPOSED MODULES"
                (Just "elm.json")
                "Your elm.json has no \"exposed-modules\" which means there is no public API at all right now! What am I supposed to diff?"
                [ "Try adding some modules back to the \"exposed-modules\" field." |> D.reflow
                ]

        DiffUnpublished ->
            Help.report "UNPUBLISHED"
                Nothing
                "This package is not published yet. There is nothing to diff against!"
                []

        DiffUnknownPackage pkg suggestions ->
            Help.report "UNKNOWN PACKAGE"
                Nothing
                "I cannot find a package called:"
                [ Pkg.toChars pkg |> D.fromChars |> D.red |> D.indent 4
                , D.fromChars "Maybe you want one of these instead?"
                , List.map (D.fromChars << Pkg.toChars) suggestions |> D.vcat |> D.dullyellow |> D.indent 4
                , D.fromChars "But check <https://package.elm-lang.org> to see all possibilities!"
                ]

        DiffUnknownVersion vsn realVersions ->
            Help.docReport "UNKNOWN VERSION"
                Nothing
                (D.fillSep <|
                    [ D.fromChars "Version"
                    , D.red (D.fromVersion vsn)
                    , D.fromChars "has"
                    , D.fromChars "never"
                    , D.fromChars "been"
                    , D.fromChars "published,"
                    , D.fromChars "so"
                    , D.fromChars "I"
                    , D.fromChars "cannot"
                    , D.fromChars "diff"
                    , D.fromChars "against"
                    , D.fromChars "it."
                    ]
                )
                [ D.fromChars "Here are all the versions that HAVE been published:"
                , (let
                    sameMajor : V.Version -> V.Version -> Bool
                    sameMajor v1 v2 =
                        V.major v1 == V.major v2

                    mkRow : List V.Version -> D.Doc
                    mkRow vsns =
                        List.map D.fromVersion vsns |> D.hsep
                   in
                   Utils.listGroupBy sameMajor (List.sortWith V.compare realVersions) |> List.map mkRow
                  )
                    |> D.vcat
                    |> D.dullyellow
                    |> D.indent 4
                , D.fromChars "Want one of those instead?"
                ]

        DiffDocsProblem version problem ->
            toDocsProblemReport problem <|
                "I need the docs for "
                    ++ V.toChars version
                    ++ " to compute this diff"

        DiffMustHaveLatestRegistry problem ->
            "I need the latest list of published packages before I do this diff" |> toRegistryProblemReport "PROBLEM UPDATING PACKAGE LIST" problem

        DiffBadDetails details ->
            toDetailsReport details

        DiffBadBuild buildProblem ->
            toBuildProblemReport buildProblem



-- ====== BUMP ======


{-| Error conditions that can occur when bumping package versions.
-}
type Bump
    = BumpNoOutline
    | BumpBadOutline Outline
    | BumpApplication
    | BumpUnexpectedVersion V.Version (List V.Version)
    | BumpMustHaveLatestRegistry RegistryProblem
    | BumpCannotFindDocs V.Version DocsProblem
    | BumpBadDetails Details
    | BumpNoExposed
    | BumpBadBuild BuildProblem


{-| Converts a bump error to a user-friendly report.
-}
bumpToReport : Bump -> Help.Report
bumpToReport bump =
    case bump of
        BumpNoOutline ->
            Help.report "BUMP WHAT?"
                Nothing
                "I cannot find an elm.json so I am not sure what you want me to bump."
                [ D.reflow <|
                    "Elm packages always have an elm.json that says the current version number. If you run this "
                        ++ "command from a directory with an elm.json file, I will try to bump the version in there "
                        ++ "based on the API changes."
                ]

        BumpBadOutline outline ->
            toOutlineReport outline

        BumpApplication ->
            Help.report "CANNOT BUMP APPLICATIONS"
                (Just "elm.json")
                "Your elm.json says this is an application. That means it cannot be published on <https://package.elm-lang.org> and therefore has no version to bump!"
                []

        BumpUnexpectedVersion vsn versions ->
            Help.docReport "CANNOT BUMP"
                (Just "elm.json")
                (D.fillSep
                    [ D.fromChars "Your"
                    , D.fromChars "elm.json"
                    , D.fromChars "says"
                    , D.fromChars "I"
                    , D.fromChars "should"
                    , D.fromChars "bump"
                    , D.fromChars "relative"
                    , D.fromChars "to"
                    , D.fromChars "version"
                    , D.red (D.fromVersion vsn)
                        |> D.a (D.fromChars ",")
                    , D.fromChars "but"
                    , D.fromChars "I"
                    , D.fromChars "cannot"
                    , D.fromChars "find"
                    , D.fromChars "that"
                    , D.fromChars "version"
                    , D.fromChars "on"
                    , D.fromChars "<https://package.elm-lang.org>."
                    , D.fromChars "That"
                    , D.fromChars "means"
                    , D.fromChars "there"
                    , D.fromChars "is"
                    , D.fromChars "no"
                    , D.fromChars "API"
                    , D.fromChars "for"
                    , D.fromChars "me"
                    , D.fromChars "to"
                    , D.fromChars "diff"
                    , D.fromChars "against"
                    , D.fromChars "and"
                    , D.fromChars "figure"
                    , D.fromChars "out"
                    , D.fromChars "if"
                    , D.fromChars "these"
                    , D.fromChars "are"
                    , D.fromChars "MAJOR,"
                    , D.fromChars "MINOR,"
                    , D.fromChars "or"
                    , D.fromChars "PATCH"
                    , D.fromChars "changes."
                    ]
                )
                [ D.fillSep <|
                    [ D.fromChars "Try"
                    , D.fromChars "bumping"
                    , D.fromChars "again"
                    , D.fromChars "after"
                    , D.fromChars "changing"
                    , D.fromChars "the"
                    , D.dullyellow (D.fromChars "\"version\"")
                    , D.fromChars "in"
                    , D.fromChars "elm.json"
                    ]
                        ++ (if List.length versions == 1 then
                                [ D.fromChars "to:" ]

                            else
                                [ D.fromChars "to"
                                , D.fromChars "one"
                                , D.fromChars "of"
                                , D.fromChars "these:"
                                ]
                           )
                , List.map (D.green << D.fromVersion) versions |> D.vcat
                ]

        BumpMustHaveLatestRegistry problem ->
            "I need the latest list of published packages before I can bump any versions" |> toRegistryProblemReport "PROBLEM UPDATING PACKAGE LIST" problem

        BumpCannotFindDocs version problem ->
            toDocsProblemReport problem <|
                "I need the docs for "
                    ++ V.toChars version
                    ++ " to compute the next version number"

        BumpBadDetails details ->
            toDetailsReport details

        BumpNoExposed ->
            Help.docReport "NO EXPOSED MODULES"
                (Just "elm.json")
                (D.fillSep <|
                    [ D.fromChars "To"
                    , D.fromChars "bump"
                    , D.fromChars "a"
                    , D.fromChars "package,"
                    , D.fromChars "the"
                    , D.dullyellow (D.fromChars "\"exposed-modules\"")
                    , D.fromChars "field"
                    , D.fromChars "of"
                    , D.fromChars "your"
                    , D.fromChars "elm.json"
                    , D.fromChars "must"
                    , D.fromChars "list"
                    , D.fromChars "at"
                    , D.fromChars "least"
                    , D.fromChars "one"
                    , D.fromChars "module."
                    ]
                )
                [ "Try adding some modules back to the \"exposed-modules\" field." |> D.reflow
                ]

        BumpBadBuild problem ->
            toBuildProblemReport problem

-- ====== DOCS ======


{-| Error conditions that can occur when loading package documentation.
-}
type DocsProblem
    = DP_Http Http.Error
    | DP_Data String String
    | DP_Cache


toDocsProblemReport : DocsProblem -> String -> Help.Report
toDocsProblemReport problem context =
    case problem of
        DP_Http httpError ->
            toHttpErrorReport "PROBLEM LOADING DOCS" httpError context

        DP_Data url body ->
            Help.report "PROBLEM LOADING DOCS"
                Nothing
                (context ++ ", so I fetched:")
                [ D.fromChars url |> D.dullyellow |> D.indent 4
                , D.reflow <|
                    "I got the data back, but it was not what I was expecting. The response body contains "
                        ++ body
                        ++ " bytes. Here is the "
                        ++ (if String.length body <= 76 then
                                "whole thing:"

                            else
                                "beginning:"
                           )
                , (if String.length body <= 76 then
                    body

                   else
                    String.left 73 body ++ "..."
                  )
                    |> D.fromChars
                    |> D.dullyellow
                    |> D.indent 4
                , D.reflow <|
                    "Does this error keep showing up? Maybe there is something weird with your internet "
                        ++ "connection. We have gotten reports that schools, businesses, airports, etc. sometimes "
                        ++ "intercept requests and add things to the body or change its contents entirely. Could "
                        ++ "that be the problem?"
                ]

        DP_Cache ->
            Help.report "PROBLEM LOADING DOCS"
                Nothing
                (context ++ ", but the local copy seems to be corrupted.")
                [ D.reflow <|
                    "I deleted the cached version, so the next run should download a fresh copy of the docs. "
                        ++ "Hopefully that will get you unstuck, but it will not resolve the root problem if, for example, "
                        ++ "a 3rd party editor plugin is modifing cached files for some reason."
                ]



-- ====== INSTALL ======


{-| Error conditions that can occur when installing packages.
-}
type Install
    = InstallNoOutline
    | InstallBadOutline Outline
    | InstallBadRegistry RegistryProblem
    | InstallNoArgs FilePath
    | InstallNoOnlineAppSolution Pkg.Name
    | InstallNoOfflineAppSolution Pkg.Name
    | InstallNoOnlinePkgSolution Pkg.Name
    | InstallNoOfflinePkgSolution Pkg.Name
    | InstallHadSolverTrouble Solver
    | InstallUnknownPackageOnline Pkg.Name (List Pkg.Name)
    | InstallUnknownPackageOffline Pkg.Name (List Pkg.Name)
    | InstallBadDetails Details


{-| Converts an install error to a user-friendly report.
-}
installToReport : Install -> Help.Report
installToReport exit =
    case exit of
        InstallNoOutline ->
            Help.report "NEW PROJECT?"
                Nothing
                "Are you trying to start a new project? Try this command instead:"
                [ D.green (D.fromChars "eco init") |> D.indent 4
                , D.reflow "It will help you get started!"
                ]

        InstallBadOutline outline ->
            toOutlineReport outline

        InstallBadRegistry problem ->
            "I need the list of published packages to figure out how to install things" |> toRegistryProblemReport "PROBLEM LOADING PACKAGE LIST" problem

        InstallNoArgs elmHome ->
            Help.report "INSTALL WHAT?"
                Nothing
                "I am expecting commands like:"
                [ [ D.fromChars "eco install elm/http"
                  , D.fromChars "eco install elm/json"
                  , D.fromChars "eco install elm/random"
                  ]
                    |> D.vcat
                    |> D.indent 4
                    |> D.green
                , D.toFancyHint
                    [ D.fromChars "In"
                    , D.fromChars "JavaScript"
                    , D.fromChars "folks"
                    , D.fromChars "run"
                    , D.fromChars "`npm install`"
                    , D.fromChars "to"
                    , D.fromChars "start"
                    , D.fromChars "projects."
                    , D.fromChars "\"Gotta"
                    , D.fromChars "download"
                    , D.fromChars "everything!\""
                    , D.fromChars "But"
                    , D.fromChars "why"
                    , D.fromChars "download"
                    , D.fromChars "packages"
                    , D.fromChars "again"
                    , D.fromChars "and"
                    , D.fromChars "again?"
                    , D.fromChars "Instead,"
                    , D.fromChars "Elm"
                    , D.fromChars "caches"
                    , D.fromChars "packages"
                    , D.fromChars "in"
                    , D.dullyellow (D.fromChars elmHome)
                    , D.fromChars "so"
                    , D.fromChars "each"
                    , D.fromChars "one"
                    , D.fromChars "is"
                    , D.fromChars "downloaded"
                    , D.fromChars "and"
                    , D.fromChars "built"
                    , D.fromChars "ONCE"
                    , D.fromChars "on"
                    , D.fromChars "your"
                    , D.fromChars "machine."
                    , D.fromChars "Elm"
                    , D.fromChars "projects"
                    , D.fromChars "check"
                    , D.fromChars "that"
                    , D.fromChars "cache"
                    , D.fromChars "before"
                    , D.fromChars "trying"
                    , D.fromChars "the"
                    , D.fromChars "internet."
                    , D.fromChars "This"
                    , D.fromChars "reduces"
                    , D.fromChars "build"
                    , D.fromChars "times,"
                    , D.fromChars "reduces"
                    , D.fromChars "server"
                    , D.fromChars "costs,"
                    , D.fromChars "and"
                    , D.fromChars "makes"
                    , D.fromChars "it"
                    , D.fromChars "easier"
                    , D.fromChars "to"
                    , D.fromChars "work"
                    , D.fromChars "offline."
                    , D.fromChars "As"
                    , D.fromChars "a"
                    , D.fromChars "result"
                    , D.dullcyan (D.fromChars "elm install")
                    , D.fromChars "is"
                    , D.fromChars "only"
                    , D.fromChars "for"
                    , D.fromChars "adding"
                    , D.fromChars "dependencies"
                    , D.fromChars "to"
                    , D.fromChars "elm.json,"
                    , D.fromChars "whereas"
                    , D.dullcyan (D.fromChars "elm make")
                    , D.fromChars "is"
                    , D.fromChars "in"
                    , D.fromChars "charge"
                    , D.fromChars "of"
                    , D.fromChars "gathering"
                    , D.fromChars "dependencies"
                    , D.fromChars "and"
                    , D.fromChars "building"
                    , D.fromChars "everything."
                    , D.fromChars "So"
                    , D.fromChars "maybe"
                    , D.fromChars "try"
                    , D.green (D.fromChars "elm make")
                    , D.fromChars "instead?"
                    ]
                ]

        InstallNoOnlineAppSolution pkg ->
            Help.report "CANNOT FIND COMPATIBLE VERSION"
                (Just "elm.json")
                ("I cannot find a version of " ++ Pkg.toChars pkg ++ " that is compatible with your existing dependencies.")
                [ D.reflow <|
                    "I checked all the published versions. When that failed, I tried to find any compatible "
                        ++ "combination of these packages, even if it meant changing all your existing dependencies! "
                        ++ "That did not work either!"
                , D.reflow <|
                    "This is most likely to happen when a package is not upgraded yet. Maybe a new version of "
                        ++ "Elm came out recently? Maybe a common package was changed recently? Maybe a better package "
                        ++ "came along, so there was no need to upgrade this one? Try asking around "
                        ++ "https://elm-lang.org/community to learn what might be going on with this package."
                , D.toSimpleNote <|
                    "Whatever the case, please be kind to the relevant package authors! Having friendly "
                        ++ "interactions with users is great motivation, and conversely, getting berated by strangers "
                        ++ "on the internet sucks your soul dry. Furthermore, package authors are humans with families, "
                        ++ "friends, jobs, vacations, responsibilities, goals, etc. They face obstacles outside of their "
                        ++ "technical work you will never know about, so please assume the best and try to be patient "
                        ++ "and supportive!"
                ]

        InstallNoOfflineAppSolution pkg ->
            Help.report "CANNOT FIND COMPATIBLE VERSION LOCALLY"
                (Just "elm.json")
                ("I cannot find a version of " ++ Pkg.toChars pkg ++ " that is compatible with your existing dependencies.")
                [ "I was not able to connect to https://package.elm-lang.org/ though, so I was only able to look through packages that you have downloaded in the past." |> D.reflow
                , "Try again later when you have internet!" |> D.reflow
                ]

        InstallNoOnlinePkgSolution pkg ->
            Help.report "CANNOT FIND COMPATIBLE VERSION"
                (Just "elm.json")
                ("I cannot find a version of " ++ Pkg.toChars pkg ++ " that is compatible with your existing constraints.")
                [ D.reflow <|
                    "With applications, I try to broaden the constraints to see if anything works, but messing "
                        ++ "with package constraints is much more delicate business. E.g. making your constraints stricter "
                        ++ "may make it harder for applications to find compatible dependencies. So fixing something here "
                        ++ "may break it for a lot of other people!"
                , D.reflow <|
                    "So I recommend making an application with the same dependencies as your package. See if "
                        ++ "there is a solution at all. From there it may be easier to figure out how to proceed in a way "
                        ++ "that will disrupt your users as little as possible. And the solution may be to help other "
                        ++ "package authors to get their packages updated, or to drop a dependency entirely."
                ]

        InstallNoOfflinePkgSolution pkg ->
            Help.report "CANNOT FIND COMPATIBLE VERSION LOCALLY"
                (Just "elm.json")
                ("I cannot find a version of " ++ Pkg.toChars pkg ++ " that is compatible with your existing constraints.")
                [ "I was not able to connect to https://package.elm-lang.org/ though, so I was only able to look through packages that you have downloaded in the past." |> D.reflow
                , "Try again later when you have internet!" |> D.reflow
                ]

        InstallHadSolverTrouble solver ->
            toSolverReport solver

        InstallUnknownPackageOnline pkg suggestions ->
            Help.docReport "UNKNOWN PACKAGE"
                Nothing
                (D.fillSep
                    [ D.fromChars "I"
                    , D.fromChars "cannot"
                    , D.fromChars "find"
                    , D.fromChars "a"
                    , D.fromChars "package"
                    , D.fromChars "named"
                    , D.red (D.fromPackage pkg)
                        |> D.a (D.fromChars ".")
                    ]
                )
                [ "I looked through https://package.elm-lang.org for packages with similar names and found these:" |> D.reflow
                , List.map D.fromPackage suggestions |> D.vcat |> D.dullyellow |> D.indent 4
                , "Maybe you want one of these instead?" |> D.reflow
                ]

        InstallUnknownPackageOffline pkg suggestions ->
            Help.docReport "UNKNOWN PACKAGE"
                Nothing
                (D.fillSep
                    [ D.fromChars "I"
                    , D.fromChars "cannot"
                    , D.fromChars "find"
                    , D.fromChars "a"
                    , D.fromChars "package"
                    , D.fromChars "named"
                    , D.red (D.fromPackage pkg)
                        |> D.a (D.fromChars ".")
                    ]
                )
                [ "I could not connect to https://package.elm-lang.org though, so new packages may have been published since I last updated my local cache of package names." |> D.reflow
                , "Looking through the locally cached names, the closest ones are:" |> D.reflow
                , List.map D.fromPackage suggestions |> D.vcat |> D.dullyellow |> D.indent 4
                , "Maybe you want one of these instead?" |> D.reflow
                ]

        InstallBadDetails details ->
            toDetailsReport details



-- ====== UNINSTALL ======


{-| Error conditions that can occur when uninstalling packages.
-}
type Uninstall
    = UninstallNoOutline
    | UninstallBadOutline Outline
    | UninstallBadRegistry RegistryProblem
    | UninstallNoArgs
    | UninstallNoOnlineAppSolution Pkg.Name
    | UninstallNoOfflineAppSolution Pkg.Name
    | UninstallHadSolverTrouble Solver
    | UninstallBadDetails Details


{-| Converts an uninstall error to a user-friendly report.
-}
uninstallToReport : Uninstall -> Help.Report
uninstallToReport exit =
    case exit of
        UninstallNoOutline ->
            Help.report "NEW PROJECT?"
                Nothing
                "Are you trying to start a new project? Try this command instead:"
                [ D.green (D.fromChars "eco init") |> D.indent 4
                , D.reflow "It will help you get started!"
                ]

        UninstallBadOutline outline ->
            toOutlineReport outline

        UninstallBadRegistry problem ->
            "I need the list of published packages to figure out how to uninstall things" |> toRegistryProblemReport "PROBLEM LOADING PACKAGE LIST" problem

        UninstallNoArgs ->
            Help.report "UNINSTALL WHAT?"
                Nothing
                "I am expecting commands like:"
                [ [ D.fromChars "eco uninstall elm/http"
                  , D.fromChars "eco uninstall elm/json"
                  , D.fromChars "eco uninstall elm/random"
                  ]
                    |> D.vcat
                    |> D.indent 4
                    |> D.green
                ]

        UninstallNoOnlineAppSolution pkg ->
            Help.report "CANNOT FIND COMPATIBLE VERSION"
                (Just "elm.json")
                ("I cannot find a version of " ++ Pkg.toChars pkg ++ " that is compatible with your existing dependencies.")
                [ D.reflow <|
                    "I checked all the published versions. When that failed, I tried to find any compatible "
                        ++ "combination of these packages, even if it meant changing all your existing dependencies! "
                        ++ "That did not work either!"
                , D.reflow <|
                    "This is most likely to happen when a package is not upgraded yet. Maybe a new version of "
                        ++ "Elm came out recently? Maybe a common package was changed recently? Maybe a better package "
                        ++ "came along, so there was no need to upgrade this one? Try asking around "
                        ++ "https://elm-lang.org/community to learn what might be going on with this package."
                , D.toSimpleNote <|
                    "Whatever the case, please be kind to the relevant package authors! Having friendly "
                        ++ "interactions with users is great motivation, and conversely, getting berated by strangers "
                        ++ "on the internet sucks your soul dry. Furthermore, package authors are humans with families, "
                        ++ "friends, jobs, vacations, responsibilities, goals, etc. They face obstacles outside of their "
                        ++ "technical work you will never know about, so please assume the best and try to be patient "
                        ++ "and supportive!"
                ]

        UninstallNoOfflineAppSolution pkg ->
            Help.report "CANNOT FIND COMPATIBLE VERSION LOCALLY"
                (Just "elm.json")
                ("I cannot find a version of " ++ Pkg.toChars pkg ++ " that is compatible with your existing dependencies.")
                [ "I was not able to connect to https://package.elm-lang.org/ though, so I was only able to look through packages that you have downloaded in the past." |> D.reflow
                , "Try again later when you have internet!" |> D.reflow
                ]

        UninstallHadSolverTrouble solver ->
            toSolverReport solver

        UninstallBadDetails details ->
            toDetailsReport details



-- ====== SOLVER ======


{-| Error conditions that can occur during dependency resolution.
-}
type Solver
    = SolverBadCacheData Pkg.Name V.Version
    | SolverBadHttpData Pkg.Name V.Version String
    | SolverBadHttp Pkg.Name V.Version Http.Error


toSolverReport : Solver -> Help.Report
toSolverReport problem =
    case problem of
        SolverBadCacheData pkg vsn ->
            Help.report "PROBLEM SOLVING PACKAGE CONSTRAINTS"
                Nothing
                ("I need the elm.json of "
                    ++ Pkg.toChars pkg
                    ++ " "
                    ++ V.toChars vsn
                    ++ " to help me search for a set of compatible packages. I had it cached locally, but it looks like the file was corrupted!"
                )
                [ D.reflow <|
                    "I deleted the cached version, so the next run should download a fresh copy. "
                        ++ "Hopefully that will get you unstuck, but it will not resolve the root problem "
                        ++ "if a 3rd party tool is modifing cached files for some reason."
                ]

        SolverBadHttpData pkg vsn url ->
            Help.report "PROBLEM SOLVING PACKAGE CONSTRAINTS"
                Nothing
                ("I need the elm.json of "
                    ++ Pkg.toChars pkg
                    ++ " "
                    ++ V.toChars vsn
                    ++ " to help me search for a set of compatible packages, but I ran into corrupted information from:"
                )
                [ D.fromChars url |> D.dullyellow |> D.indent 4
                , D.reflow <|
                    "Is something weird with your internet connection. "
                        ++ "We have gotten reports that schools, businesses, airports, etc. sometimes intercept requests "
                        ++ "and add things to the body or change its contents entirely. Could that be the problem?"
                ]

        SolverBadHttp pkg vsn httpError ->
            toHttpErrorReport "PROBLEM SOLVING PACKAGE CONSTRAINTS" httpError <|
                "I need the elm.json of "
                    ++ Pkg.toChars pkg
                    ++ " "
                    ++ V.toChars vsn
                    ++ " to help me search for a set of compatible packages"



-- ====== OUTLINE ======


{-| Error conditions that can occur when parsing elm.json files.
-}
type Outline
    = OutlineHasBadStructure (Decode.Error OutlineProblem)
    | OutlineHasMissingSrcDirs FilePath (List FilePath)
    | OutlineHasDuplicateSrcDirs FilePath FilePath FilePath
    | OutlineNoPkgCore
    | OutlineNoAppCore
    | OutlineNoAppJson


{-| Specific problems with elm.json structure and content.
-}
type OutlineProblem
    = OP_BadType
    | OP_BadPkgName Row Col
    | OP_BadVersion Row Col
    | OP_BadConstraint C.Error
    | OP_BadModuleName Row Col
    | OP_BadModuleHeaderTooLong
    | OP_BadDependencyName Row Col
    | OP_BadLicense (List String)
    | OP_BadSummaryTooLong
    | OP_NoSrcDirs


toOutlineReport : Outline -> Help.Report
toOutlineReport problem =
    case problem of
        OutlineHasBadStructure decodeError ->
            Json.ExplicitReason "I ran into a problem with your elm.json file." |> Json.toReport "elm.json" (Json.FailureToReport toOutlineProblemReport) decodeError

        OutlineHasMissingSrcDirs dir dirs ->
            case dirs of
                [] ->
                    Help.report "MISSING SOURCE DIRECTORY"
                        (Just "elm.json")
                        "I need a valid elm.json file, but the \"source-directories\" field lists the following directory:"
                        [ D.fromChars dir |> D.red |> D.indent 4
                        , "I cannot find it though. Is it missing? Is there a typo?" |> D.reflow
                        ]

                _ :: _ ->
                    Help.report "MISSING SOURCE DIRECTORIES"
                        (Just "elm.json")
                        "I need a valid elm.json file, but the \"source-directories\" field lists the following directories:"
                        [ List.map (D.red << D.fromChars) (dir :: dirs) |> D.vcat |> D.indent 4
                        , "I cannot find them though. Are they missing? Are there typos?" |> D.reflow
                        ]

        OutlineHasDuplicateSrcDirs canonicalDir dir1 dir2 ->
            if dir1 == dir2 then
                Help.report "REDUNDANT SOURCE DIRECTORIES"
                    (Just "elm.json")
                    "I need a valid elm.json file, but the \"source-directories\" field lists the same directory twice:"
                    [ List.map (D.red << D.fromChars) [ dir1, dir2 ] |> D.vcat |> D.indent 4
                    , "Remove one of the entries!" |> D.reflow
                    ]

            else
                Help.report "REDUNDANT SOURCE DIRECTORIES"
                    (Just "elm.json")
                    "I need a valid elm.json file, but the \"source-directories\" field has some redundant directories:"
                    [ List.map (D.red << D.fromChars) [ dir1, dir2 ] |> D.vcat |> D.indent 4
                    , "These are two different ways of refering to the same directory:" |> D.reflow
                    , D.fromChars canonicalDir |> D.dullyellow |> D.indent 4
                    , "Remove one of the redundant entries from your \"source-directories\" field." |> D.reflow
                    ]

        OutlineNoPkgCore ->
            Help.report "MISSING DEPENDENCY"
                (Just "elm.json")
                "I need to see an \"elm/core\" dependency your elm.json file. The default imports of `List` and `Maybe` do not work without it."
                [ D.reflow <|
                    "If you modified your elm.json by hand, try to change it back! "
                        ++ "And if you are having trouble getting back to a working elm.json, "
                        ++ "it may be easier to find a working package and start fresh with their elm.json file."
                ]

        OutlineNoAppCore ->
            Help.report "MISSING DEPENDENCY"
                (Just "elm.json")
                "I need to see an \"elm/core\" dependency your elm.json file. The default imports of `List` and `Maybe` do not work without it."
                [ D.reflow <|
                    "If you modified your elm.json by hand, try to change it back! "
                        ++ "And if you are having trouble getting back to a working elm.json, "
                        ++ "it may be easier to delete it and use `elm init` to start fresh."
                ]

        OutlineNoAppJson ->
            Help.report "MISSING DEPENDENCY"
                (Just "elm.json")
                "I need to see an \"elm/json\" dependency your elm.json file. It helps me handle flags and ports."
                [ D.reflow <|
                    "If you modified your elm.json by hand, try to change it back! "
                        ++ "And if you are having trouble getting back to a working elm.json, "
                        ++ "it may be easier to delete it and use `elm init` to start fresh."
                ]


toOutlineProblemReport : FilePath -> Code.Source -> Json.Context -> A.Region -> OutlineProblem -> Help.Report
toOutlineProblemReport path source _ region problem =
    let
        toHighlight : Int -> Int -> Maybe A.Region
        toHighlight row col =
            A.Region (A.Position row col) (A.Position row col) |> Just

        toSnippet : String -> Maybe A.Region -> ( D.Doc, D.Doc ) -> Help.Report
        toSnippet title highlight pair =
            Code.toSnippet source region highlight pair |> Help.jsonReport title (Just path)
    in
    case problem of
        OP_BadType ->
            toSnippet "UNEXPECTED TYPE"
                Nothing
                ( "I got stuck while reading your elm.json file. I cannot handle a \"type\" like this:" |> D.reflow
                , D.fillSep
                    [ D.fromChars "Try"
                    , D.fromChars "changing"
                    , D.fromChars "the"
                    , D.fromChars "\"type\""
                    , D.fromChars "to"
                    , D.green (D.fromChars "\"application\"")
                    , D.fromChars "or"
                    , D.green (D.fromChars "\"package\"")
                    , D.fromChars "instead."
                    ]
                )

        OP_BadPkgName row col ->
            toSnippet "INVALID PACKAGE NAME"
                (toHighlight row col)
                ( "I got stuck while reading your elm.json file. I ran into trouble with the package name:" |> D.reflow
                , D.stack
                    [ D.fillSep
                        [ D.fromChars "Package"
                        , D.fromChars "names"
                        , D.fromChars "are"
                        , D.fromChars "always"
                        , D.fromChars "written"
                        , D.fromChars "as"
                        , D.green (D.fromChars "\"author/project\"")
                        , D.fromChars "so"
                        , D.fromChars "I"
                        , D.fromChars "am"
                        , D.fromChars "expecting"
                        , D.fromChars "to"
                        , D.fromChars "see"
                        , D.fromChars "something"
                        , D.fromChars "like:"
                        ]
                    , [ D.fromChars "\"mdgriffith/elm-ui\""
                      , D.fromChars "\"w0rm/elm-physics\""
                      , D.fromChars "\"Microsoft/elm-json-tree-view\""
                      , D.fromChars "\"FordLabs/elm-star-rating\""
                      , D.fromChars "\"1602/json-schema\""
                      ]
                        |> D.vcat
                        |> D.indent 4
                        |> D.dullyellow
                    , D.reflow
                        "The author name should match your GitHub name exactly, and the project name needs to follow these rules:"
                    , [ D.fromChars "+--------------------------------------+-----------+-----------+"
                      , D.fromChars "| RULE                                 | BAD       | GOOD      |"
                      , D.fromChars "+--------------------------------------+-----------+-----------+"
                      , D.fromChars "| only lower case, digits, and hyphens | elm-HTTP  | elm-http  |"
                      , D.fromChars "| no leading digits                    | 3D        | elm-3d    |"
                      , D.fromChars "| no non-ASCII characters              | elm-bjørn | elm-bear  |"
                      , D.fromChars "| no underscores                       | elm_ui    | elm-ui    |"
                      , D.fromChars "| no double hyphens                    | elm--hash | elm-hash  |"
                      , D.fromChars "| no starting or ending hyphen         | -elm-tar- | elm-tar   |"
                      , D.fromChars "+--------------------------------------+-----------+-----------+"
                      ]
                        |> D.vcat
                        |> D.indent 4
                    , "These rules only apply to the project name, so you should never need to change your GitHub name!" |> D.toSimpleNote
                    ]
                )

        OP_BadVersion row col ->
            toSnippet "PROBLEM WITH VERSION"
                (toHighlight row col)
                ( "I got stuck while reading your elm.json file. I was expecting a version number here:" |> D.reflow
                , D.fillSep
                    [ D.fromChars "I"
                    , D.fromChars "need"
                    , D.fromChars "something"
                    , D.fromChars "like"
                    , D.green (D.fromChars "\"1.0.0\"")
                    , D.fromChars "or"
                    , D.green (D.fromChars "\"2.0.4\"")
                    , D.fromChars "that"
                    , D.fromChars "explicitly"
                    , D.fromChars "states"
                    , D.fromChars "all"
                    , D.fromChars "three"
                    , D.fromChars "numbers!"
                    ]
                )

        OP_BadConstraint constraintError ->
            case constraintError of
                C.BadFormat row col ->
                    toSnippet "PROBLEM WITH CONSTRAINT"
                        (toHighlight row col)
                        ( "I got stuck while reading your elm.json file. I do not understand this version constraint:" |> D.reflow
                        , D.stack
                            [ D.fillSep
                                [ D.fromChars "I"
                                , D.fromChars "need"
                                , D.fromChars "something"
                                , D.fromChars "like"
                                , D.green (D.fromChars "\"1.0.0 <= v < 2.0.0\"")
                                , D.fromChars "that"
                                , D.fromChars "explicitly"
                                , D.fromChars "lists"
                                , D.fromChars "the"
                                , D.fromChars "lower"
                                , D.fromChars "and"
                                , D.fromChars "upper"
                                , D.fromChars "bounds."
                                ]
                            , D.toSimpleNote <|
                                "The spaces in there are required! Taking them out will confuse me. "
                                    ++ "Adding extra spaces confuses me too. "
                                    ++ "I recommend starting with a valid example and just changing the version numbers."
                            ]
                        )

                C.InvalidRange before after ->
                    if before == after then
                        toSnippet "PROBLEM WITH CONSTRAINT"
                            Nothing
                            ( "I got stuck while reading your elm.json file. I ran into an invalid version constraint:" |> D.reflow
                            , D.fillSep
                                [ D.fromChars "Elm"
                                , D.fromChars "checks"
                                , D.fromChars "that"
                                , D.fromChars "all"
                                , D.fromChars "package"
                                , D.fromChars "APIs"
                                , D.fromChars "follow"
                                , D.fromChars "semantic"
                                , D.fromChars "versioning,"
                                , D.fromChars "so"
                                , D.fromChars "it"
                                , D.fromChars "is"
                                , D.fromChars "best"
                                , D.fromChars "to"
                                , D.fromChars "use"
                                , D.fromChars "wide"
                                , D.fromChars "constraints."
                                , D.fromChars "I"
                                , D.fromChars "recommend"
                                , D.green (D.fromChars "\"") |> D.a (D.fromVersion before) |> D.a (D.fromChars " <= v < ") |> D.a (D.fromVersion (V.bumpMajor after)) |> D.a (D.fromChars "\"")
                                , D.fromChars "since"
                                , D.fromChars "it"
                                , D.fromChars "is"
                                , D.fromChars "guaranteed"
                                , D.fromChars "that"
                                , D.fromChars "breaking"
                                , D.fromChars "API"
                                , D.fromChars "changes"
                                , D.fromChars "cannot"
                                , D.fromChars "happen"
                                , D.fromChars "in"
                                , D.fromChars "any"
                                , D.fromChars "of"
                                , D.fromChars "the"
                                , D.fromChars "versions"
                                , D.fromChars "in"
                                , D.fromChars "that"
                                , D.fromChars "range."
                                ]
                            )

                    else
                        toSnippet "PROBLEM WITH CONSTRAINT"
                            Nothing
                            ( "I got stuck while reading your elm.json file. I ran into an invalid version constraint:" |> D.reflow
                            , D.fillSep
                                [ D.fromChars "Maybe"
                                , D.fromChars "you"
                                , D.fromChars "want"
                                , D.fromChars "something"
                                , D.fromChars "like"
                                , D.green
                                    (D.fromChars "\""
                                        |> D.a (D.fromVersion before)
                                        |> D.a (D.fromChars " <= v < ")
                                        |> D.a (D.fromVersion (V.bumpMajor before))
                                        |> D.a (D.fromChars "\"")
                                    )
                                , D.fromChars "instead?"
                                , D.fromChars "Elm"
                                , D.fromChars "checks"
                                , D.fromChars "that"
                                , D.fromChars "all"
                                , D.fromChars "package"
                                , D.fromChars "APIs"
                                , D.fromChars "follow"
                                , D.fromChars "semantic"
                                , D.fromChars "versioning,"
                                , D.fromChars "so"
                                , D.fromChars "it"
                                , D.fromChars "is"
                                , D.fromChars "guaranteed"
                                , D.fromChars "that"
                                , D.fromChars "breaking"
                                , D.fromChars "API"
                                , D.fromChars "changes"
                                , D.fromChars "cannot"
                                , D.fromChars "happen"
                                , D.fromChars "in"
                                , D.fromChars "any"
                                , D.fromChars "of"
                                , D.fromChars "the"
                                , D.fromChars "versions"
                                , D.fromChars "in"
                                , D.fromChars "that"
                                , D.fromChars "range."
                                ]
                            )

        OP_BadModuleName row col ->
            toSnippet "PROBLEM WITH MODULE NAME"
                (toHighlight row col)
                ( "I got stuck while reading your elm.json file. I was expecting a module name here:" |> D.reflow
                , D.fillSep
                    [ D.fromChars "I"
                    , D.fromChars "need"
                    , D.fromChars "something"
                    , D.fromChars "like"
                    , D.green (D.fromChars "\"Html.Events\"")
                    , D.fromChars "or"
                    , D.green (D.fromChars "\"Browser.Navigation\"")
                    , D.fromChars "where"
                    , D.fromChars "each"
                    , D.fromChars "segment"
                    , D.fromChars "starts"
                    , D.fromChars "with"
                    , D.fromChars "a"
                    , D.fromChars "capital"
                    , D.fromChars "letter"
                    , D.fromChars "and"
                    , D.fromChars "the"
                    , D.fromChars "segments"
                    , D.fromChars "are"
                    , D.fromChars "separated"
                    , D.fromChars "by"
                    , D.fromChars "dots."
                    ]
                )

        OP_BadModuleHeaderTooLong ->
            toSnippet "HEADER TOO LONG"
                Nothing
                ( "I got stuck while reading your elm.json file. This section header is too long:" |> D.reflow
                , D.stack
                    [ D.fillSep
                        [ D.fromChars "I"
                        , D.fromChars "need"
                        , D.fromChars "it"
                        , D.fromChars "to"
                        , D.fromChars "be"
                        , D.green (D.fromChars "under")
                        , D.green (D.fromChars "20")
                        , D.green (D.fromChars "bytes")
                        , D.fromChars "so"
                        , D.fromChars "it"
                        , D.fromChars "renders"
                        , D.fromChars "nicely"
                        , D.fromChars "on"
                        , D.fromChars "the"
                        , D.fromChars "package"
                        , D.fromChars "website!"
                        ]
                    , D.toSimpleNote <|
                        "I count the length in bytes, so using non-ASCII characters costs extra. "
                            ++ "Please report your case at https://github.com/elm/compiler/issues if this seems overly restrictive for your needs."
                    ]
                )

        OP_BadDependencyName row col ->
            toSnippet "PROBLEM WITH DEPENDENCY NAME"
                (toHighlight row col)
                ( "I got stuck while reading your elm.json file. There is something wrong with this dependency name:" |> D.reflow
                , D.stack
                    [ D.fillSep
                        [ D.fromChars "Package"
                        , D.fromChars "names"
                        , D.fromChars "always"
                        , D.fromChars "include"
                        , D.fromChars "the"
                        , D.fromChars "name"
                        , D.fromChars "of"
                        , D.fromChars "the"
                        , D.fromChars "author,"
                        , D.fromChars "so"
                        , D.fromChars "I"
                        , D.fromChars "am"
                        , D.fromChars "expecting"
                        , D.fromChars "to"
                        , D.fromChars "see"
                        , D.fromChars "dependencies"
                        , D.fromChars "like"
                        , D.dullyellow (D.fromChars "\"mdgriffith/elm-ui\"")
                        , D.fromChars "and"
                        , D.dullyellow (D.fromChars "\"Microsoft/elm-json-tree-view\"")
                            |> D.a (D.fromChars ".")
                        ]
                    , D.fillSep <|
                        [ D.fromChars "I"
                        , D.fromChars "generally"
                        , D.fromChars "recommend"
                        , D.fromChars "finding"
                        , D.fromChars "the"
                        , D.fromChars "package"
                        , D.fromChars "you"
                        , D.fromChars "want"
                        , D.fromChars "on"
                        , D.fromChars "the"
                        , D.fromChars "package"
                        , D.fromChars "website,"
                        , D.fromChars "and"
                        , D.fromChars "installing"
                        , D.fromChars "it"
                        , D.fromChars "with"
                        , D.fromChars "the"
                        , D.green (D.fromChars "elm install")
                        , D.fromChars "command!"
                        ]
                    ]
                )

        OP_BadLicense suggestions ->
            toSnippet "UNKNOWN LICENSE"
                Nothing
                ( "I got stuck while reading your elm.json file. I do not know about this type of license:" |> D.reflow
                , D.stack
                    [ D.fillSep
                        [ D.fromChars "Elm"
                        , D.fromChars "packages"
                        , D.fromChars "generally"
                        , D.fromChars "use"
                        , D.green (D.fromChars "\"BSD-3-Clause\"")
                        , D.fromChars "or"
                        , D.green (D.fromChars "\"MIT\"")
                            |> D.a (D.fromChars ",")
                        , D.fromChars "but"
                        , D.fromChars "I"
                        , D.fromChars "accept"
                        , D.fromChars "any"
                        , D.fromChars "OSI"
                        , D.fromChars "approved"
                        , D.fromChars "SPDX"
                        , D.fromChars "license."
                        , D.fromChars "Here"
                        , D.fromChars "some"
                        , D.fromChars "that"
                        , D.fromChars "seem"
                        , D.fromChars "close"
                        , D.fromChars "to"
                        , D.fromChars "what"
                        , D.fromChars "you"
                        , D.fromChars "wrote:"
                        ]
                    , List.map D.fromChars suggestions |> D.vcat |> D.dullyellow |> D.indent 4
                    , "Check out https://spdx.org/licenses/ for the full list of options." |> D.reflow
                    ]
                )

        OP_BadSummaryTooLong ->
            toSnippet "SUMMARY TOO LONG"
                Nothing
                ( "I got stuck while reading your elm.json file. Your \"summary\" is too long:" |> D.reflow
                , D.stack
                    [ D.fillSep
                        [ D.fromChars "I"
                        , D.fromChars "need"
                        , D.fromChars "it"
                        , D.fromChars "to"
                        , D.fromChars "be"
                        , D.green (D.fromChars "under")
                        , D.green (D.fromChars "80")
                        , D.green (D.fromChars "bytes")
                        , D.fromChars "so"
                        , D.fromChars "it"
                        , D.fromChars "renders"
                        , D.fromChars "nicely"
                        , D.fromChars "on"
                        , D.fromChars "the"
                        , D.fromChars "package"
                        , D.fromChars "website!"
                        ]
                    , D.toSimpleNote <|
                        "I count the length in bytes, so using non-ASCII characters costs extra. "
                            ++ "Please report your case at https://github.com/elm/compiler/issues if this seems overly restrictive for your needs."
                    ]
                )

        OP_NoSrcDirs ->
            toSnippet "NO SOURCE DIRECTORIES"
                Nothing
                ( "I got stuck while reading your elm.json file. You do not have any \"source-directories\" listed here:" |> D.reflow
                , D.fillSep
                    [ D.fromChars "I"
                    , D.fromChars "need"
                    , D.fromChars "something"
                    , D.fromChars "like"
                    , D.green (D.fromChars "[\"src\"]")
                    , D.fromChars "so"
                    , D.fromChars "I"
                    , D.fromChars "know"
                    , D.fromChars "where"
                    , D.fromChars "to"
                    , D.fromChars "look"
                    , D.fromChars "for"
                    , D.fromChars "your"
                    , D.fromChars "modules!"
                    ]
                )



-- ====== DETAILS ======


{-| Error conditions that can occur during dependency resolution and validation.
-}
type Details
    = DetailsNoSolution
    | DetailsNoOfflineSolution
    | DetailsSolverProblem Solver
    | DetailsBadElmInPkg C.Constraint
    | DetailsBadElmInAppOutline V.Version
    | DetailsHandEditedDependencies
    | DetailsBadOutline Outline
    | DetailsCannotGetRegistry RegistryProblem
    | DetailsBadDeps FilePath (List DetailsBadDep)


{-| Specific dependency-related errors.
-}
type DetailsBadDep
    = BD_BadDownload Pkg.Name V.Version PackageProblem
    | BD_BadBuild Pkg.Name V.Version (Dict ( String, String ) Pkg.Name V.Version)


toDetailsReport : Details -> Help.Report
toDetailsReport details =
    case details of
        DetailsNoSolution ->
            Help.report "INCOMPATIBLE DEPENDENCIES"
                (Just "elm.json")
                "The dependencies in your elm.json are not compatible."
                [ D.fillSep
                    [ D.fromChars "Did"
                    , D.fromChars "you"
                    , D.fromChars "change"
                    , D.fromChars "them"
                    , D.fromChars "by"
                    , D.fromChars "hand?"
                    , D.fromChars "Try"
                    , D.fromChars "to"
                    , D.fromChars "change"
                    , D.fromChars "it"
                    , D.fromChars "back!"
                    , D.fromChars "It"
                    , D.fromChars "is"
                    , D.fromChars "much"
                    , D.fromChars "more"
                    , D.fromChars "reliable"
                    , D.fromChars "to"
                    , D.fromChars "add"
                    , D.fromChars "dependencies"
                    , D.fromChars "with"
                    , D.green (D.fromChars "elm install")
                        |> D.a (D.fromChars ".")
                    ]
                , "Please ask for help on the community forums if you try those paths and are still having problems!" |> D.reflow
                ]

        DetailsNoOfflineSolution ->
            Help.report "TROUBLE VERIFYING DEPENDENCIES"
                (Just "elm.json")
                "I could not connect to https://package.elm-lang.org to get the latest list of packages, and I was unable to verify your dependencies with the information I have cached locally."
                [ "Are you able to connect to the internet? These dependencies may work once you get access to the registry!" |> D.reflow
                , D.toFancyNote
                    [ D.fromChars "If"
                    , D.fromChars "you"
                    , D.fromChars "changed"
                    , D.fromChars "your"
                    , D.fromChars "dependencies"
                    , D.fromChars "by"
                    , D.fromChars "hand,"
                    , D.fromChars "try"
                    , D.fromChars "to"
                    , D.fromChars "change"
                    , D.fromChars "them"
                    , D.fromChars "back!"
                    , D.fromChars "It"
                    , D.fromChars "is"
                    , D.fromChars "much"
                    , D.fromChars "more"
                    , D.fromChars "reliable"
                    , D.fromChars "to"
                    , D.fromChars "add"
                    , D.fromChars "dependencies"
                    , D.fromChars "with"
                    , D.green (D.fromChars "elm install")
                        |> D.a (D.fromChars ".")
                    ]
                ]

        DetailsSolverProblem solver ->
            toSolverReport solver

        DetailsBadElmInPkg constraint ->
            Help.report "ELM VERSION MISMATCH"
                (Just "elm.json")
                "Your elm.json says this package needs a version of Elm in this range:"
                [ C.toChars constraint |> D.fromChars |> D.dullyellow |> D.indent 4
                , D.fillSep
                    [ D.fromChars "But"
                    , D.fromChars "you"
                    , D.fromChars "are"
                    , D.fromChars "using"
                    , D.fromChars "Elm"
                    , D.red (D.fromVersion V.compiler)
                    , D.fromChars "right"
                    , D.fromChars "now."
                    ]
                ]

        DetailsBadElmInAppOutline version ->
            Help.report "ELM VERSION MISMATCH"
                (Just "elm.json")
                "Your elm.json says this application needs a different version of Elm."
                [ D.fillSep
                    [ D.fromChars "It"
                    , D.fromChars "requires"
                    , D.green (D.fromVersion version)
                        |> D.a (D.fromChars ",")
                    , D.fromChars "but"
                    , D.fromChars "you"
                    , D.fromChars "are"
                    , D.fromChars "using"
                    , D.red (D.fromVersion V.compiler)
                    , D.fromChars "right"
                    , D.fromChars "now."
                    ]
                ]

        DetailsHandEditedDependencies ->
            Help.report "ERROR IN DEPENDENCIES"
                (Just "elm.json")
                "It looks like the dependencies elm.json in were edited by hand (or by a 3rd party tool) leaving them in an invalid state."
                [ D.fillSep
                    [ D.fromChars "Try"
                    , D.fromChars "to"
                    , D.fromChars "change"
                    , D.fromChars "them"
                    , D.fromChars "back"
                    , D.fromChars "to"
                    , D.fromChars "what"
                    , D.fromChars "they"
                    , D.fromChars "were"
                    , D.fromChars "before!"
                    , D.fromChars "It"
                    , D.fromChars "is"
                    , D.fromChars "much"
                    , D.fromChars "more"
                    , D.fromChars "reliable"
                    , D.fromChars "to"
                    , D.fromChars "add"
                    , D.fromChars "dependencies"
                    , D.fromChars "with"
                    , D.green (D.fromChars "elm install")
                        |> D.a (D.fromChars ".")
                    ]
                , "Please ask for help on the community forums if you try those paths and are still having problems!" |> D.reflow
                ]

        DetailsBadOutline outline ->
            toOutlineReport outline

        DetailsCannotGetRegistry problem ->
            "I need the list of published packages to verify your dependencies" |> toRegistryProblemReport "PROBLEM LOADING PACKAGE LIST" problem

        DetailsBadDeps cacheDir deps ->
            case List.sortBy toBadDepRank deps of
                [] ->
                    Help.report "PROBLEM BUILDING DEPENDENCIES"
                        Nothing
                        "I am not sure what is going wrong though."
                        [ D.reflow <|
                            "I would try deleting the "
                                ++ cacheDir
                                ++ " and eco-stuff/ directories, then trying to build again. That will work if some cached files got corrupted somehow."
                        , "If that does not work, go to https://elm-lang.org/community and ask for help. This is a weird case!" |> D.reflow
                        ]

                d :: _ ->
                    case d of
                        BD_BadDownload pkg vsn packageProblem ->
                            toPackageProblemReport pkg vsn packageProblem

                        BD_BadBuild pkg vsn fingerprint ->
                            Help.report "PROBLEM BUILDING DEPENDENCIES"
                                Nothing
                                "I ran into a compilation error when trying to build the following package:"
                                [ (Pkg.toChars pkg ++ " " ++ V.toChars vsn) |> D.fromChars |> D.red |> D.indent 4
                                , D.reflow <|
                                    "This probably means it has package constraints that are too wide. "
                                        ++ "It may be possible to tweak your elm.json to avoid the root problem as a stopgap. "
                                        ++ "Head over to https://elm-lang.org/community to get help figuring out how to take this path!"
                                , D.toSimpleNote <|
                                    "To help with the root problem, please report this to the package author "
                                        ++ "along with the following information:"
                                , Dict.toList compare fingerprint |> List.map (\( p, v ) -> (Pkg.toChars p ++ " " ++ V.toChars v) |> D.fromChars) |> D.vcat |> D.indent 4
                                , D.reflow <|
                                    "If you want to help out even more, try building the package locally. "
                                        ++ "That should give you much more specific information about why this package is failing to build, "
                                        ++ "which will in turn make it easier for the package author to fix it!"
                                ]


toBadDepRank :
    DetailsBadDep
    -> Int -- lower is better
toBadDepRank badDep =
    case badDep of
        BD_BadDownload _ _ _ ->
            0

        BD_BadBuild _ _ _ ->
            1



-- ====== PACKAGE PROBLEM ======


{-| Error conditions that can occur when downloading packages.
-}
type PackageProblem
    = PP_BadEndpointRequest Http.Error
    | PP_BadEndpointContent String
    | PP_BadArchiveRequest Http.Error
    | PP_BadArchiveContent String
    | PP_BadArchiveHash String String String


toPackageProblemReport : Pkg.Name -> V.Version -> PackageProblem -> Help.Report
toPackageProblemReport pkg vsn problem =
    let
        thePackage : String
        thePackage =
            Pkg.toChars pkg ++ " " ++ V.toChars vsn
    in
    case problem of
        PP_BadEndpointRequest httpError ->
            toHttpErrorReport "PROBLEM DOWNLOADING PACKAGE" httpError <|
                "I need to find the latest download link for "
                    ++ thePackage

        PP_BadEndpointContent url ->
            Help.report "PROBLEM DOWNLOADING PACKAGE"
                Nothing
                ("I need to find the latest download link for " ++ thePackage ++ ", but I ran into corrupted information from:")
                [ D.fromChars url |> D.dullyellow |> D.indent 4
                , D.reflow <|
                    "Is something weird with your internet connection. "
                        ++ "We have gotten reports that schools, businesses, airports, etc. sometimes intercept requests "
                        ++ "and add things to the body or change its contents entirely. Could that be the problem?"
                ]

        PP_BadArchiveRequest httpError ->
            toHttpErrorReport "PROBLEM DOWNLOADING PACKAGE" httpError <|
                "I was trying to download the source code for "
                    ++ thePackage

        PP_BadArchiveContent url ->
            Help.report "PROBLEM DOWNLOADING PACKAGE"
                Nothing
                ("I downloaded the source code for " ++ thePackage ++ " from:")
                [ D.fromChars url |> D.dullyellow |> D.indent 4
                , D.reflow <|
                    "But I was unable to unzip the data. Maybe there is something weird with your internet connection. "
                        ++ "We have gotten reports that schools, businesses, airports, etc. sometimes intercept requests "
                        ++ "and add things to the body or change its contents entirely. Could that be the problem?"
                ]

        PP_BadArchiveHash url expectedHash actualHash ->
            Help.report "CORRUPT PACKAGE DATA"
                Nothing
                ("I downloaded the source code for " ++ thePackage ++ " from:")
                [ D.fromChars url |> D.dullyellow |> D.indent 4
                , D.reflow "But it looks like the hash of the archive has changed since publication:"
                , [ "  Expected: " ++ expectedHash
                  , "    Actual: " ++ actualHash
                  ]
                    |> List.map D.fromChars
                    |> D.vcat
                , "This usually means that the package author moved the version tag, so report it to them and see if that is the issue. Folks on Elm slack can probably help as well." |> D.reflow
                ]



-- ====== REGISTRY PROBLEM ======


{-| Error conditions that can occur when accessing the package registry.
-}
type RegistryProblem
    = RP_Http Http.Error
    | RP_Data String String


toRegistryProblemReport : String -> RegistryProblem -> String -> Help.Report
toRegistryProblemReport title problem context =
    case problem of
        RP_Http err ->
            toHttpErrorReport title err context

        RP_Data url body ->
            Help.report title
                Nothing
                (context ++ ", so I fetched:")
                [ D.fromChars url |> D.dullyellow |> D.indent 4
                , D.reflow <|
                    "I got the data back, but it was not what I was expecting. The response body contains "
                        ++ String.fromInt (String.length body)
                        ++ " bytes. Here is the "
                        ++ (if String.length body <= 76 then
                                "whole thing:"

                            else
                                "beginning:"
                           )
                , (if String.length body <= 76 then
                    body

                   else
                    String.left 73 body ++ "..."
                  )
                    |> D.fromChars
                    |> D.dullyellow
                    |> D.indent 4
                , D.reflow <|
                    "Does this error keep showing up? Maybe there is something weird with your internet "
                        ++ "connection. We have gotten reports that schools, businesses, airports, etc. sometimes "
                        ++ "intercept requests and add things to the body or change its contents entirely. Could "
                        ++ "that be the problem?"
                ]


toHttpErrorReport : String -> Http.Error -> String -> Help.Report
toHttpErrorReport title err context =
    let
        toHttpReport : String -> String -> List D.Doc -> Help.Report
        toHttpReport intro url details =
            Help.report title Nothing intro <|
                D.indent 4 (D.dullyellow (D.fromChars url))
                    :: details
    in
    case err of
        Http.BadUrl url reason ->
            toHttpReport (context ++ ", so I wanted to fetch:")
                url
                [ "But my HTTP library is saying this is not a valid URL. It is saying:" |> D.reflow
                , D.fromChars reason |> D.indent 4
                , D.reflow <|
                    "This may indicate that there is some problem in the compiler, so please open an issue at "
                        ++ "https://github.com/elm/compiler/issues listing your operating system, Elm version, the command "
                        ++ "you ran, the terminal output, and any additional information that might help others reproduce the error."
                ]

        Http.BadHttp url httpExceptionContent ->
            case httpExceptionContent of
                Utils.StatusCodeException response body ->
                    let
                        (Utils.HttpStatus code message) =
                            Utils.httpResponseStatus response
                    in
                    toHttpReport (context ++ ", so I tried to fetch:")
                        url
                        [ D.fillSep <|
                            [ D.fromChars "But"
                            , D.fromChars "it"
                            , D.fromChars "came"
                            , D.fromChars "back"
                            , D.fromChars "as"
                            , D.red (D.fromInt code)
                            ]
                                ++ List.map D.fromChars (String.words message)
                        , body |> D.reflow |> D.indent 4
                        , D.reflow <|
                            "This may mean some online endpoint changed in an unexpected way, so if does not seem like "
                                ++ "something on your side is causing this (e.g. firewall) please report this to "
                                ++ "https://github.com/elm/compiler/issues with your operating system, Elm version, "
                                ++ "the command you ran, the terminal output, and any additional information that can help others reproduce the error!"
                        ]

                Utils.TooManyRedirects responses ->
                    toHttpReport (context ++ ", so I tried to fetch:")
                        url
                        [ D.reflow <|
                            "But I gave up after following these "
                                ++ String.fromInt (List.length responses)
                                ++ " redirects:"
                        , List.map toRedirectDoc responses |> D.vcat |> D.indent 4
                        , D.reflow <|
                            "Is it possible that your internet connection intercepts certain requests? "
                                ++ "That sometimes causes problems for folks in schools, businesses, airports, hotels, and certain countries. "
                                ++ "Try asking for help locally or in a community forum!"
                        ]

                _ ->
                    toHttpReport (context ++ ", so I tried to fetch:")
                        url
                        [ "But my HTTP library is giving me the following error message:" |> D.reflow
                        , D.fromChars "TODO" |> D.indent 4
                        , D.reflow <|
                            "Are you somewhere with a slow internet connection? Or no internet? "
                                ++ "Does the link I am trying to fetch work in your browser? "
                                ++ "Maybe the site is down? Does your internet connection have a firewall that blocks certain domains? "
                                ++ "It is usually something like that!"
                        ]

        Http.BadMystery url Utils.SomeException ->
            toHttpReport (context ++ ", so I tried to fetch:")
                url
                [ "But I ran into something weird! I was able to extract this error message:" |> D.reflow
                , D.fromChars "SomeException" |> D.indent 4
                , D.reflow <|
                    "Is it possible that your internet connection intercepts certain requests? "
                        ++ "That sometimes causes problems for folks in schools, businesses, airports, hotels, and certain countries. "
                        ++ "Try asking for help locally or in a community forum!"
                ]


toRedirectDoc : Utils.HttpResponse body -> D.Doc
toRedirectDoc response =
    let
        (Utils.HttpStatus code message) =
            Utils.httpResponseStatus response
    in
    case Utils.listLookup Utils.httpHLocation (Utils.httpResponseHeaders response) of
        Just loc ->
            D.red (D.fromInt code) |> D.a (D.fromChars " - ") |> D.a (D.fromChars loc)

        Nothing ->
            D.red (D.fromInt code) |> D.a (D.fromChars " - ") |> D.a (D.fromChars message)



-- ====== MAKE ======


{-| Error conditions that can occur during the make/build process.
-}
type Make
    = MakeNoOutline
    | MakeCannotOptimizeAndDebug
    | MakeBadDetails Details
    | MakeAppNeedsFileNames
    | MakePkgNeedsExposing
    | MakeMultipleFilesIntoHtml
    | MakeNoMain
    | MakeNonMainFilesIntoJavaScript ModuleName.Raw (List ModuleName.Raw)
    | MakeCannotBuild BuildProblem
    | MakeBadGenerate Generate


{-| Converts a make error to a user-friendly report.
-}
makeToReport : Make -> Help.Report
makeToReport make =
    case make of
        MakeNoOutline ->
            Help.report "NO elm.json FILE"
                Nothing
                "It looks like you are starting a new Elm project. Very exciting! Try running:"
                [ D.fromChars "elm init" |> D.green |> D.indent 4
                , "It will help you get set up. It is really simple!" |> D.reflow
                ]

        MakeCannotOptimizeAndDebug ->
            Help.docReport "CLASHING FLAGS"
                Nothing
                (D.fillSep
                    [ D.fromChars "I"
                    , D.fromChars "cannot"
                    , D.fromChars "compile"
                    , D.fromChars "with"
                    , D.red (D.fromChars "--optimize")
                    , D.fromChars "and"
                    , D.red (D.fromChars "--debug")
                    , D.fromChars "at"
                    , D.fromChars "the"
                    , D.fromChars "same"
                    , D.fromChars "time."
                    ]
                )
                [ D.reflow <|
                    "I need to take away information to optimize things, and I need to add information to add the debugger. "
                        ++ "It is impossible to do both at once though! Pick just one of those flags and it should work!"
                ]

        MakeBadDetails detailsProblem ->
            toDetailsReport detailsProblem

        MakeAppNeedsFileNames ->
            Help.report "NO INPUT"
                Nothing
                "What should I make though? I need specific files like:"
                [ D.vcat
                    [ D.green (D.fromChars "elm make src/Main.elm") |> D.indent 4
                    , D.green (D.fromChars "elm make src/This.elm src/That.elm") |> D.indent 4
                    ]
                , "I recommend reading through https://guide.elm-lang.org for guidance on what to actually put in those files!" |> D.reflow
                ]

        MakePkgNeedsExposing ->
            Help.report "NO INPUT"
                Nothing
                "What should I make though? I need specific files like:"
                [ D.vcat
                    [ D.green (D.fromChars "elm make src/Main.elm") |> D.indent 4
                    , D.green (D.fromChars "elm make src/This.elm src/That.elm") |> D.indent 4
                    ]
                , "You can also entries to the \"exposed-modules\" list in your elm.json file, and I will try to compile the relevant files." |> D.reflow
                ]

        MakeMultipleFilesIntoHtml ->
            Help.report "TOO MANY FILES"
                Nothing
                "When producing an HTML file, I can only handle one file."
                [ D.fillSep
                    [ D.fromChars "Switch"
                    , D.fromChars "to"
                    , D.dullyellow (D.fromChars "--output=/dev/null")
                    , D.fromChars "if"
                    , D.fromChars "you"
                    , D.fromChars "just"
                    , D.fromChars "want"
                    , D.fromChars "to"
                    , D.fromChars "get"
                    , D.fromChars "compile"
                    , D.fromChars "errors."
                    , D.fromChars "This"
                    , D.fromChars "skips"
                    , D.fromChars "the"
                    , D.fromChars "code"
                    , D.fromChars "gen"
                    , D.fromChars "phase,"
                    , D.fromChars "so"
                    , D.fromChars "it"
                    , D.fromChars "can"
                    , D.fromChars "be"
                    , D.fromChars "a"
                    , D.fromChars "bit"
                    , D.fromChars "faster"
                    , D.fromChars "than"
                    , D.fromChars "other"
                    , D.fromChars "options"
                    , D.fromChars "sometimes."
                    ]
                , D.fillSep
                    [ D.fromChars "Switch"
                    , D.fromChars "to"
                    , D.dullyellow (D.fromChars "--output=elm.js")
                    , D.fromChars "if"
                    , D.fromChars "you"
                    , D.fromChars "want"
                    , D.fromChars "multiple"
                    , D.fromChars "`main`"
                    , D.fromChars "values"
                    , D.fromChars "available"
                    , D.fromChars "in"
                    , D.fromChars "a"
                    , D.fromChars "single"
                    , D.fromChars "JavaScript"
                    , D.fromChars "file."
                    , D.fromChars "Then"
                    , D.fromChars "you"
                    , D.fromChars "can"
                    , D.fromChars "make"
                    , D.fromChars "your"
                    , D.fromChars "own"
                    , D.fromChars "customized"
                    , D.fromChars "HTML"
                    , D.fromChars "file"
                    , D.fromChars "that"
                    , D.fromChars "embeds"
                    , D.fromChars "multiple"
                    , D.fromChars "Elm"
                    , D.fromChars "nodes."
                    , D.fromChars "The"
                    , D.fromChars "generated"
                    , D.fromChars "JavaScript"
                    , D.fromChars "also"
                    , D.fromChars "shares"
                    , D.fromChars "dependencies"
                    , D.fromChars "between"
                    , D.fromChars "modules,"
                    , D.fromChars "so"
                    , D.fromChars "it"
                    , D.fromChars "should"
                    , D.fromChars "be"
                    , D.fromChars "smaller"
                    , D.fromChars "than"
                    , D.fromChars "compiling"
                    , D.fromChars "each"
                    , D.fromChars "module"
                    , D.fromChars "separately."
                    ]
                ]

        MakeNoMain ->
            Help.report "NO MAIN"
                Nothing
                "When producing an HTML file, I require that the given file has a `main` value. That way I have something to show on screen!"
                [ "Try adding a `main` value to your file? Or if you just want to verify that this module compiles, switch to --output=/dev/null to skip the code gen phase altogether." |> D.reflow
                , "Adding a `main` value can be as brief as adding something like this:" |> D.toSimpleNote
                , D.vcat
                    [ D.fillSep
                        [ D.cyan (D.fromChars "import")
                        , D.fromChars "Html"
                        ]
                    , D.fromChars ""
                    , D.fillSep
                        [ D.green (D.fromChars "main")
                        , D.fromChars "="
                        ]
                    , D.indent 2 <|
                        D.fillSep
                            [ D.cyan (D.fromChars "Html")
                                |> D.a (D.fromChars ".text")
                            , D.dullyellow (D.fromChars "\"Hello!\"")
                            ]
                    ]
                , "From there I can create an HTML file that says \"Hello!\" on screen. I recommend looking through https://guide.elm-lang.org for more guidance on how to fill in the `main` value." |> D.reflow
                ]

        MakeNonMainFilesIntoJavaScript m ms ->
            case ms of
                [] ->
                    Help.report "NO MAIN"
                        Nothing
                        ("When producing a JS file, I require that the given file has a `main` value. That way Elm."
                            ++ String.fromList (N.toChars m)
                            ++ ".init() is definitely defined in the resulting file!"
                        )
                        [ "Try adding a `main` value to your file? Or if you just want to verify that this module compiles, switch to --output=/dev/null to skip the code gen phase altogether." |> D.reflow
                        , "Adding a `main` value can be as brief as adding something like this:" |> D.toSimpleNote
                        , D.vcat
                            [ D.fillSep
                                [ D.cyan (D.fromChars "import")
                                , D.fromChars "Html"
                                ]
                            , D.fromChars ""
                            , D.fillSep
                                [ D.green (D.fromChars "main")
                                , D.fromChars "="
                                ]
                            , D.indent 2 <|
                                D.fillSep
                                    [ D.cyan (D.fromChars "Html")
                                        |> D.a (D.fromChars ".text")
                                    , D.dullyellow (D.fromChars "\"Hello!\"")
                                    ]
                            ]
                        , "Or use https://package.elm-lang.org/packages/elm/core/latest/Platform#worker to make a `main` with no user interface." |> D.reflow
                        ]

                _ :: _ ->
                    Help.report "NO MAIN"
                        Nothing
                        ("When producing a JS file, I require that given files all have `main` values. That way functions like Elm."
                            ++ String.fromList (N.toChars m)
                            ++ ".init() are definitely defined in the resulting file. I am missing `main` values in:"
                        )
                        [ List.map D.fromName (m :: ms) |> D.vcat |> D.red |> D.indent 4
                        , "Try adding a `main` value to them? Or if you just want to verify that these modules compile, switch to --output=/dev/null to skip the code gen phase altogether." |> D.reflow
                        , "Adding a `main` value can be as brief as adding something like this:" |> D.toSimpleNote
                        , D.vcat
                            [ D.fillSep
                                [ D.cyan (D.fromChars "import")
                                , D.fromChars "Html"
                                ]
                            , D.fromChars ""
                            , D.fillSep
                                [ D.green (D.fromChars "main")
                                , D.fromChars "="
                                ]
                            , D.indent 2 <|
                                D.fillSep
                                    [ D.cyan (D.fromChars "Html")
                                        |> D.a (D.fromChars ".text")
                                    , D.dullyellow (D.fromChars "\"Hello!\"")
                                    ]
                            ]
                        , "Or use https://package.elm-lang.org/packages/elm/core/latest/Platform#worker to make a `main` with no user interface." |> D.reflow
                        ]

        MakeCannotBuild buildProblem ->
            toBuildProblemReport buildProblem

        MakeBadGenerate generateProblem ->
            toGenerateReport generateProblem



-- ====== BUILD PROBLEM ======


{-| Represents compilation failures, either from bad modules or project-level issues.
-}
type BuildProblem
    = BuildBadModules FilePath Error.Module (List Error.Module)
    | BuildProjectProblem BuildProjectProblem


{-| Project-level build problems that affect the entire build.
-}
type BuildProjectProblem
    = BP_PathUnknown FilePath
    | BP_WithBadExtension FilePath
    | BP_WithAmbiguousSrcDir FilePath FilePath FilePath
    | BP_MainPathDuplicate FilePath FilePath
    | BP_RootNameDuplicate ModuleName.Raw FilePath FilePath
    | BP_RootNameInvalid FilePath FilePath (List String)
    | BP_CannotLoadDependencies
    | BP_Cycle ModuleName.Raw (List ModuleName.Raw)
    | BP_MissingExposed (NE.Nonempty ( ModuleName.Raw, Import.Problem ))


toBuildProblemReport : BuildProblem -> Help.Report
toBuildProblemReport problem =
    case problem of
        BuildBadModules root e es ->
            Help.compilerReport root e es

        BuildProjectProblem projectProblem ->
            toProjectProblemReport projectProblem


toProjectProblemReport : BuildProjectProblem -> Help.Report
toProjectProblemReport projectProblem =
    case projectProblem of
        BP_PathUnknown path ->
            Help.report "FILE NOT FOUND"
                Nothing
                "I cannot find this file:"
                [ D.fromChars path |> D.red |> D.indent 4
                , "Is there a typo?" |> D.reflow
                , D.toSimpleNote <|
                    "If you are just getting started, try working through the examples in the official guide "
                        ++ "https://guide.elm-lang.org to get an idea of the kinds of things that typically go in a src/Main.elm file."
                ]

        BP_WithBadExtension path ->
            Help.report "UNEXPECTED FILE EXTENSION"
                Nothing
                "I can only compile Elm files (with a .elm extension) but you want me to compile:"
                [ D.fromChars path |> D.red |> D.indent 4
                , "Is there a typo? Can the file extension be changed?" |> D.reflow
                ]

        BP_WithAmbiguousSrcDir path srcDir1 srcDir2 ->
            Help.report "CONFUSING FILE"
                Nothing
                "I am getting confused when I try to compile this file:"
                [ D.fromChars path |> D.red |> D.indent 4
                , D.reflow <|
                    "I always check if files appear in any of the \"source-directories\" listed in your elm.json "
                        ++ "to see if there might be some cached information about them. That can help me compile faster! "
                        ++ "But in this case, it looks like this file may be in either of these directories:"
                , List.map D.fromChars [ srcDir1, srcDir2 ] |> D.vcat |> D.red |> D.indent 4
                , "Try to make it so no source directory contains another source directory!" |> D.reflow
                ]

        BP_MainPathDuplicate path1 path2 ->
            Help.report "CONFUSING FILES"
                Nothing
                "You are telling me to compile these two files:"
                [ List.map D.fromChars [ path1, path2 ] |> D.vcat |> D.red |> D.indent 4
                , D.reflow <|
                    if path1 == path2 then
                        "Why are you telling me twice? Is something weird going on with a script? "
                            ++ "I figured I would let you know about it just in case something is wrong. "
                            ++ "Only list it once and you should be all set!"

                    else
                        "But seem to be the same file though... It makes me think something tricky is going on with symlinks "
                            ++ "in your project, so I figured I would let you know about it just in case. "
                            ++ "Remove one of these files from your command to get unstuck!"
                ]

        BP_RootNameDuplicate name outsidePath otherPath ->
            Help.report "MODULE NAME CLASH"
                Nothing
                "These two files are causing a module name clash:"
                [ List.map D.fromChars [ outsidePath, otherPath ] |> D.vcat |> D.red |> D.indent 4
                , D.reflow <|
                    "They both say `module "
                        ++ String.fromList (N.toChars name)
                        ++ " exposing (..)` up at the top, but they cannot have the same name!"
                , "Try changing to a different module name in one of them!" |> D.reflow
                ]

        BP_RootNameInvalid givenPath srcDir _ ->
            Help.report "UNEXPECTED FILE NAME"
                Nothing
                "I am having trouble with this file name:"
                [ D.fromChars givenPath |> D.red |> D.indent 4
                , D.reflow <|
                    "I found it in your "
                        ++ Utils.fpAddTrailingPathSeparator srcDir
                        ++ " directory which is good, but I expect all of the files in there to use the following module naming convention:"
                , toModuleNameConventionTable srcDir [ "Main", "HomePage", "Http.Helpers" ]
                , "Notice that the names always start with capital letters! Can you make your file use this naming convention?" |> D.reflow
                , D.toSimpleNote <|
                    "Having a strict naming convention like this makes it a lot easier to find things in large projects. "
                        ++ "If you see a module imported, you know where to look for the corresponding file every time!"
                ]

        BP_CannotLoadDependencies ->
            corruptCacheReport

        BP_Cycle name names ->
            Help.report "IMPORT CYCLE"
                Nothing
                "Your module imports form a cycle:"
                [ D.cycle 4 name names
                , D.reflow <|
                    "Learn more about why this is disallowed and how to break cycles here:"
                        ++ D.makeLink "import-cycles"
                ]

        BP_MissingExposed (NE.Nonempty ( name, problem ) _) ->
            case problem of
                Import.NotFound ->
                    Help.report "MISSING MODULE"
                        (Just "elm.json")
                        "The  \"exposed-modules\" of your elm.json lists the following module:"
                        [ D.fromName name |> D.red |> D.indent 4
                        , "But I cannot find it in your src/ directory. Is there a typo? Was it renamed?" |> D.reflow
                        ]

                Import.Ambiguous _ _ pkg _ ->
                    Help.report "AMBIGUOUS MODULE NAME"
                        (Just "elm.json")
                        "The  \"exposed-modules\" of your elm.json lists the following module:"
                        [ D.fromName name |> D.red |> D.indent 4
                        , D.reflow <|
                            "But a module from "
                                ++ Pkg.toChars pkg
                                ++ " already uses that name. Try choosing a different name for your local file."
                        ]

                Import.AmbiguousLocal path1 path2 paths ->
                    Help.report "AMBIGUOUS MODULE NAME"
                        (Just "elm.json")
                        "The  \"exposed-modules\" of your elm.json lists the following module:"
                        [ D.fromName name |> D.red |> D.indent 4
                        , "But I found multiple files with that name:" |> D.reflow
                        , List.map D.fromChars (path1 :: path2 :: paths) |> D.vcat |> D.indent 4 |> D.dullyellow
                        , "Change the module names to be distinct!" |> D.reflow
                        ]

                Import.AmbiguousForeign _ _ _ ->
                    Help.report "MISSING MODULE"
                        (Just "elm.json")
                        "The  \"exposed-modules\" of your elm.json lists the following module:"
                        [ D.fromName name |> D.red |> D.indent 4
                        , "But I cannot find it in your src/ directory. Is there a typo? Was it renamed?" |> D.reflow
                        , "It is not possible to \"re-export\" modules from other packages. You can only expose modules that you define in your own code." |> D.toSimpleNote
                        ]


toModuleNameConventionTable : FilePath -> List String -> D.Doc
toModuleNameConventionTable srcDir names =
    let
        toPair : String -> ( String, FilePath )
        toPair name =
            ( name
            , Utils.fpCombine srcDir
                (Utils.fpAddExtension
                    (String.map
                        (\c ->
                            if c == '.' then
                                Utils.fpPathSeparator

                            else
                                c
                        )
                        name
                    )
                    "elm"
                )
            )

        namePairs : List ( String, FilePath )
        namePairs =
            List.map toPair names

        nameWidth : Int
        nameWidth =
            Utils.listMaximum compare (11 :: List.map (String.length << Tuple.first) namePairs)

        pathWidth : Int
        pathWidth =
            Utils.listMaximum compare (9 :: List.map (String.length << Tuple.second) namePairs)

        padded : Int -> String -> String
        padded width str =
            str ++ String.repeat (width - String.length str) " "

        toRow : ( String, String ) -> D.Doc
        toRow ( name, path ) =
            D.fromChars <|
                "| "
                    ++ padded nameWidth name
                    ++ " | "
                    ++ padded pathWidth path
                    ++ " |"

        bar : D.Doc
        bar =
            D.fromChars <|
                "+-"
                    ++ String.repeat nameWidth "-"
                    ++ "-+-"
                    ++ String.repeat pathWidth "-"
                    ++ "-+"
    in
    ([ bar, toRow ( "Module Name", "File Path" ), bar ]
        ++ List.map toRow namePairs
        ++ [ bar ]
    )
        |> D.vcat
        |> D.indent 4



-- ====== GENERATE ======


{-| Error conditions that can occur during code generation.
-}
type Generate
    = GenerateCannotLoadArtifacts
    | GenerateCannotOptimizeDebugValues ModuleName.Raw (List ModuleName.Raw)
    | GenerateMonomorphizationError String


toGenerateReport : Generate -> Help.Report
toGenerateReport problem =
    case problem of
        GenerateCannotLoadArtifacts ->
            corruptCacheReport

        GenerateCannotOptimizeDebugValues m ms ->
            Help.report "DEBUG REMNANTS"
                Nothing
                "There are uses of the `Debug` module in the following modules:"
                [ List.map (D.fromChars << String.fromList << N.toChars) (m :: ms) |> D.vcat |> D.red |> D.indent 4
                , D.reflow "But the --optimize flag only works if all `Debug` functions are removed!"
                , "The issue is that --optimize strips out info needed by `Debug` functions. Here are two examples:" |> D.toSimpleNote
                , ("(1) It shortens record field names. This makes the generated JavaScript smaller, "
                    ++ "but `Debug.toString` cannot know the real field names anymore."
                  )
                    |> D.reflow
                    |> D.indent 4
                , ("(2) Values like `type Height = Height Float` are unboxed. This reduces allocation, "
                    ++ "but it also means that `Debug.toString` cannot tell if it is looking at a `Height` or `Float` value."
                  )
                    |> D.reflow
                    |> D.indent 4
                , D.reflow <|
                    "There are a few other cases like that, and it will be much worse once we start inlining code. "
                        ++ "That optimization could move `Debug.log` and `Debug.todo` calls, resulting in unpredictable behavior. "
                        ++ "I hope that clarifies why this restriction exists!"
                ]

        GenerateMonomorphizationError errorMessage ->
            Help.report "MONOMORPHIZATION ERROR"
                Nothing
                "An error occurred during monomorphization:"
                [ D.fromChars errorMessage |> D.red |> D.indent 4
                , "This is likely a compiler bug. Please report it with a minimal reproduction case." |> D.reflow
                ]



-- ====== CORRUPT CACHE ======


corruptCacheReport : Help.Report
corruptCacheReport =
    Help.report "CORRUPT CACHE"
        Nothing
        "It looks like some of the information cached in eco-stuff/ has been corrupted."
        [ "Try deleting your eco-stuff/ directory to get unstuck." |> D.reflow
        , D.toSimpleNote <|
            "This almost certainly means that a 3rd party tool (or editor plugin) is causing problems "
                ++ "to the eco-stuff/ directory. Try disabling 3rd party tools one by one until you figure out which it is!"
        ]



-- ====== REPL ======


{-| Error conditions that can occur during REPL evaluation.
-}
type Repl
    = ReplBadDetails Details
    | ReplBadInput String Error.Error
    | ReplBadLocalDeps FilePath Error.Module (List Error.Module)
    | ReplProjectProblem BuildProjectProblem
    | ReplBadGenerate Generate
    | ReplBadCache
    | ReplBlocked


{-| Converts a REPL error to a user-friendly report.
-}
replToReport : Repl -> Help.Report
replToReport problem =
    case problem of
        ReplBadDetails details ->
            toDetailsReport details

        ReplBadInput source err ->
            Help.compilerReport "/" (Error.Module N.replModule "REPL" File.zeroTime source err) []

        ReplBadLocalDeps root e es ->
            Help.compilerReport root e es

        ReplProjectProblem projectProblem ->
            toProjectProblemReport projectProblem

        ReplBadGenerate generate ->
            toGenerateReport generate

        ReplBadCache ->
            corruptCacheReport

        ReplBlocked ->
            corruptCacheReport



-- ====== TEST ======


{-| Error conditions that can occur when running tests.
-}
type Test
    = TestNoOutline
    | TestBadOutline Outline
    | TestBadRegistry RegistryProblem
    | TestNoOnlineAppSolution Pkg.Name
    | TestNoOfflineAppSolution Pkg.Name
    | TestNoOnlinePkgSolution Pkg.Name
    | TestNoOfflinePkgSolution Pkg.Name
    | TestHadSolverTrouble Solver
    | TestUnknownPackageOnline Pkg.Name (List Pkg.Name)
    | TestUnknownPackageOffline Pkg.Name (List Pkg.Name)
    | TestBadDetails Details
    | TestCannotBuild BuildProblem
    | TestBadGenerate Generate


{-| Converts a test error to a user-friendly report.
-}
testToReport : Test -> Help.Report
testToReport test =
    case test of
        TestNoOutline ->
            Help.report "TEST WHAT?"
                Nothing
                "I cannot find an elm.json so I am not sure what you want me to test."
                [ "Elm packages always have an elm.json that states the version number, dependencies, exposed modules, etc." |> D.reflow
                ]

        TestBadOutline outline ->
            toOutlineReport outline

        TestBadRegistry problem ->
            "I need the list of published packages to figure out how to install things" |> toRegistryProblemReport "PROBLEM LOADING PACKAGE LIST" problem

        TestNoOnlineAppSolution pkg ->
            Help.report "CANNOT FIND COMPATIBLE VERSION"
                (Just "elm.json")
                ("I cannot find a version of " ++ Pkg.toChars pkg ++ " that is compatible with your existing dependencies.")
                [ D.reflow <|
                    "I checked all the published versions. When that failed, I tried to find any compatible "
                        ++ "combination of these packages, even if it meant changing all your existing dependencies! "
                        ++ "That did not work either!"
                , D.reflow <|
                    "This is most likely to happen when a package is not upgraded yet. Maybe a new version of "
                        ++ "Elm came out recently? Maybe a common package was changed recently? Maybe a better package "
                        ++ "came along, so there was no need to upgrade this one? Try asking around "
                        ++ "https://elm-lang.org/community to learn what might be going on with this package."
                , D.toSimpleNote <|
                    "Whatever the case, please be kind to the relevant package authors! Having friendly "
                        ++ "interactions with users is great motivation, and conversely, getting berated by strangers "
                        ++ "on the internet sucks your soul dry. Furthermore, package authors are humans with families, "
                        ++ "friends, jobs, vacations, responsibilities, goals, etc. They face obstacles outside of their "
                        ++ "technical work you will never know about, so please assume the best and try to be patient "
                        ++ "and supportive!"
                ]

        TestNoOfflineAppSolution pkg ->
            Help.report "CANNOT FIND COMPATIBLE VERSION LOCALLY"
                (Just "elm.json")
                ("I cannot find a version of " ++ Pkg.toChars pkg ++ " that is compatible with your existing dependencies.")
                [ "I was not able to connect to https://package.elm-lang.org/ though, so I was only able to look through packages that you have downloaded in the past." |> D.reflow
                , "Try again later when you have internet!" |> D.reflow
                ]

        TestNoOnlinePkgSolution pkg ->
            Help.report "CANNOT FIND COMPATIBLE VERSION"
                (Just "elm.json")
                ("I cannot find a version of " ++ Pkg.toChars pkg ++ " that is compatible with your existing constraints.")
                [ D.reflow <|
                    "With applications, I try to broaden the constraints to see if anything works, but messing "
                        ++ "with package constraints is much more delicate business. E.g. making your constraints stricter "
                        ++ "may make it harder for applications to find compatible dependencies. So fixing something here "
                        ++ "may break it for a lot of other people!"
                , D.reflow <|
                    "So I recommend making an application with the same dependencies as your package. See if "
                        ++ "there is a solution at all. From there it may be easier to figure out how to proceed in a way "
                        ++ "that will disrupt your users as little as possible. And the solution may be to help other "
                        ++ "package authors to get their packages updated, or to drop a dependency entirely."
                ]

        TestNoOfflinePkgSolution pkg ->
            Help.report "CANNOT FIND COMPATIBLE VERSION LOCALLY"
                (Just "elm.json")
                ("I cannot find a version of " ++ Pkg.toChars pkg ++ " that is compatible with your existing constraints.")
                [ "I was not able to connect to https://package.elm-lang.org/ though, so I was only able to look through packages that you have downloaded in the past." |> D.reflow
                , "Try again later when you have internet!" |> D.reflow
                ]

        TestHadSolverTrouble solver ->
            toSolverReport solver

        TestUnknownPackageOnline pkg suggestions ->
            Help.docReport "UNKNOWN PACKAGE"
                Nothing
                (D.fillSep
                    [ D.fromChars "I"
                    , D.fromChars "cannot"
                    , D.fromChars "find"
                    , D.fromChars "a"
                    , D.fromChars "package"
                    , D.fromChars "named"
                    , D.red (D.fromPackage pkg)
                        |> D.a (D.fromChars ".")
                    ]
                )
                [ "I looked through https://package.elm-lang.org for packages with similar names and found these:" |> D.reflow
                , List.map D.fromPackage suggestions |> D.vcat |> D.dullyellow |> D.indent 4
                , "Maybe you want one of these instead?" |> D.reflow
                ]

        TestUnknownPackageOffline pkg suggestions ->
            Help.docReport "UNKNOWN PACKAGE"
                Nothing
                (D.fillSep
                    [ D.fromChars "I"
                    , D.fromChars "cannot"
                    , D.fromChars "find"
                    , D.fromChars "a"
                    , D.fromChars "package"
                    , D.fromChars "named"
                    , D.red (D.fromPackage pkg)
                        |> D.a (D.fromChars ".")
                    ]
                )
                [ "I could not connect to https://package.elm-lang.org though, so new packages may have been published since I last updated my local cache of package names." |> D.reflow
                , "Looking through the locally cached names, the closest ones are:" |> D.reflow
                , List.map D.fromPackage suggestions |> D.vcat |> D.dullyellow |> D.indent 4
                , "Maybe you want one of these instead?" |> D.reflow
                ]

        TestBadDetails details ->
            toDetailsReport details

        TestCannotBuild buildProblem ->
            toBuildProblemReport buildProblem

        TestBadGenerate generateProblem ->
            toGenerateReport generateProblem



-- ====== ENCODERS and DECODERS ======


{-| Encodes a dependency error to bytes for serialization.
-}
detailsBadDepEncoder : DetailsBadDep -> Bytes.Encode.Encoder
detailsBadDepEncoder detailsBadDep =
    case detailsBadDep of
        BD_BadDownload pkg vsn packageProblem ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , Pkg.nameEncoder pkg
                , V.versionEncoder vsn
                , packageProblemEncoder packageProblem
                ]

        BD_BadBuild pkg vsn fingerprint ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , Pkg.nameEncoder pkg
                , V.versionEncoder vsn
                , BE.assocListDict compare Pkg.nameEncoder V.versionEncoder fingerprint
                ]


{-| Decodes a dependency error from bytes.
-}
detailsBadDepDecoder : Bytes.Decode.Decoder DetailsBadDep
detailsBadDepDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map3 BD_BadDownload
                            Pkg.nameDecoder
                            V.versionDecoder
                            packageProblemDecoder

                    1 ->
                        Bytes.Decode.map3 BD_BadBuild
                            Pkg.nameDecoder
                            V.versionDecoder
                            (BD.assocListDict identity Pkg.nameDecoder V.versionDecoder)

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a build problem to bytes for serialization.
-}
buildProblemEncoder : BuildProblem -> Bytes.Encode.Encoder
buildProblemEncoder buildProblem =
    case buildProblem of
        BuildBadModules root e es ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , BE.string root
                , Error.moduleEncoder e
                , BE.list Error.moduleEncoder es
                ]

        BuildProjectProblem problem ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , buildProjectProblemEncoder problem
                ]


{-| Decodes a build problem from bytes.
-}
buildProblemDecoder : Bytes.Decode.Decoder BuildProblem
buildProblemDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map3 BuildBadModules
                            BD.string
                            Error.moduleDecoder
                            (BD.list Error.moduleDecoder)

                    1 ->
                        Bytes.Decode.map BuildProjectProblem buildProjectProblemDecoder

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a project-level build problem to bytes for serialization.
-}
buildProjectProblemEncoder : BuildProjectProblem -> Bytes.Encode.Encoder
buildProjectProblemEncoder buildProjectProblem =
    case buildProjectProblem of
        BP_PathUnknown path ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , BE.string path
                ]

        BP_WithBadExtension path ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.string path
                ]

        BP_WithAmbiguousSrcDir path srcDir1 srcDir2 ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , BE.string path
                , BE.string srcDir1
                , BE.string srcDir2
                ]

        BP_MainPathDuplicate path1 path2 ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , BE.string path1
                , BE.string path2
                ]

        BP_RootNameDuplicate name outsidePath otherPath ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , ModuleName.rawEncoder name
                , BE.string outsidePath
                , BE.string otherPath
                ]

        BP_RootNameInvalid givenPath srcDir names ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , BE.string givenPath
                , BE.string srcDir
                , BE.list BE.string names
                ]

        BP_CannotLoadDependencies ->
            Bytes.Encode.unsignedInt8 6

        BP_Cycle name names ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 7
                , ModuleName.rawEncoder name
                , BE.list ModuleName.rawEncoder names
                ]

        BP_MissingExposed problems ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 8
                , BE.nonempty (BE.jsonPair ModuleName.rawEncoder Import.problemEncoder) problems
                ]


{-| Decodes a project-level build problem from bytes.
-}
buildProjectProblemDecoder : Bytes.Decode.Decoder BuildProjectProblem
buildProjectProblemDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map BP_PathUnknown BD.string

                    1 ->
                        Bytes.Decode.map BP_WithBadExtension BD.string

                    2 ->
                        Bytes.Decode.map3 BP_WithAmbiguousSrcDir
                            BD.string
                            BD.string
                            BD.string

                    3 ->
                        Bytes.Decode.map2 BP_MainPathDuplicate
                            BD.string
                            BD.string

                    4 ->
                        Bytes.Decode.map3 BP_RootNameDuplicate
                            ModuleName.rawDecoder
                            BD.string
                            BD.string

                    5 ->
                        Bytes.Decode.map3 BP_RootNameInvalid
                            BD.string
                            BD.string
                            (BD.list BD.string)

                    6 ->
                        Bytes.Decode.succeed BP_CannotLoadDependencies

                    7 ->
                        Bytes.Decode.map2 BP_Cycle
                            ModuleName.rawDecoder
                            (BD.list ModuleName.rawDecoder)

                    8 ->
                        Bytes.Decode.map BP_MissingExposed
                            (BD.nonempty
                                (BD.jsonPair ModuleName.rawDecoder Import.problemDecoder)
                            )

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a registry problem to bytes for serialization.
-}
registryProblemEncoder : RegistryProblem -> Bytes.Encode.Encoder
registryProblemEncoder registryProblem =
    case registryProblem of
        RP_Http err ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , Http.errorEncoder err
                ]

        RP_Data url body ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.string url
                , BE.string body
                ]


{-| Decodes a registry problem from bytes.
-}
registryProblemDecoder : Bytes.Decode.Decoder RegistryProblem
registryProblemDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map RP_Http Http.errorDecoder

                    1 ->
                        Bytes.Decode.map2 RP_Data
                            BD.string
                            BD.string

                    _ ->
                        Bytes.Decode.fail
            )


packageProblemEncoder : PackageProblem -> Bytes.Encode.Encoder
packageProblemEncoder packageProblem =
    case packageProblem of
        PP_BadEndpointRequest httpError ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , Http.errorEncoder httpError
                ]

        PP_BadEndpointContent url ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.string url
                ]

        PP_BadArchiveRequest httpError ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , Http.errorEncoder httpError
                ]

        PP_BadArchiveContent url ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , BE.string url
                ]

        PP_BadArchiveHash url expectedHash actualHash ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , BE.string url
                , BE.string expectedHash
                , BE.string actualHash
                ]


packageProblemDecoder : Bytes.Decode.Decoder PackageProblem
packageProblemDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map PP_BadEndpointRequest Http.errorDecoder

                    1 ->
                        Bytes.Decode.map PP_BadEndpointContent BD.string

                    2 ->
                        Bytes.Decode.map PP_BadArchiveRequest Http.errorDecoder

                    3 ->
                        Bytes.Decode.map PP_BadArchiveContent BD.string

                    4 ->
                        Bytes.Decode.map3 PP_BadArchiveHash
                            BD.string
                            BD.string
                            BD.string

                    _ ->
                        Bytes.Decode.fail
            )
