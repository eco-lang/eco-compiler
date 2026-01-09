module Terminal.Init exposing
    ( run
    , Flags(..)
    )

{-| Project initialization command for creating new Elm projects.

This module implements the `init` command which scaffolds a new Elm project by
creating an elm.json configuration file, source directories, and example test files.
It supports both application and package project types.


# Command Entry

@docs run


# Configuration

@docs Flags

-}

import Basics.Extra exposing (flip)
import Builder.Deps.Registry as Registry
import Builder.Deps.Solver as Solver
import Builder.Elm.Outline as Outline
import Builder.File as File
import Builder.Reporting as Reporting
import Builder.Reporting.Exit as Exit
import Builder.Reporting.Exit.Help as Help
import Builder.Stuff as Stuff
import Compiler.Data.NonEmptyList as NE
import Compiler.Elm.Constraint as Con
import Compiler.Elm.Licenses as Licenses
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V
import Compiler.Reporting.Doc as D
import Data.Map as Dict exposing (Dict)
import System.IO as IO
import Task exposing (Task)
import Utils.Main as Utils



-- ====== RUN ======


{-| Configuration flags for the init command.

Contains flags for package mode and auto-yes to skip confirmation prompts.

-}
type Flags
    = Flags Bool Bool


{-| Initialize a new Elm project.

Creates an elm.json file with default dependencies, sets up source directories,
and creates an example test file. Supports both application and package projects.

-}
run : () -> Flags -> Task Never ()
run () (Flags package autoYes) =
    Reporting.attempt Exit.initToReport <|
        (Utils.dirDoesFileExist "elm.json"
            |> Task.andThen (checkExistsAndAsk package autoYes)
        )


checkExistsAndAsk : Bool -> Bool -> Bool -> Task Never (Result Exit.Init ())
checkExistsAndAsk package autoYes exists =
    if exists then
        Task.succeed (Err Exit.InitAlreadyExists)

    else
        askInitQuestion autoYes
            |> Task.andThen (handleInitApproval package)


askInitQuestion : Bool -> Task Never Bool
askInitQuestion autoYes =
    if autoYes then
        Help.toStdout (information [ D.fromChars "" ])
            |> Task.map (\_ -> True)

    else
        Reporting.ask
            (information
                [ D.fromChars "Knowing all that, would you like me to create an elm.json file now? [Y/n]: "
                ]
            )


handleInitApproval : Bool -> Bool -> Task Never (Result Exit.Init ())
handleInitApproval package approved =
    if approved then
        init package

    else
        IO.putStrLn "Okay, I did not make any changes!"
            |> Task.map (\_ -> Ok ())


information : List D.Doc -> D.Doc
information question =
    D.stack
        (D.fillSep
            [ D.fromChars "Hello!"
            , D.fromChars "Elm"
            , D.fromChars "projects"
            , D.fromChars "always"
            , D.fromChars "start"
            , D.fromChars "with"
            , D.fromChars "an"
            , D.green (D.fromChars "elm.json")
            , D.fromChars "file."
            , D.fromChars "I"
            , D.fromChars "can"
            , D.fromChars "create"
            , D.fromChars "them!"
            ]
            :: D.reflow
                ("Now you may be wondering, what will be in this file? How do I add Elm files to my project? "
                    ++ "How do I see it in the browser? How will my code grow? Do I need more directories? What about tests? Etc."
                )
            :: D.fillSep
                [ D.fromChars "Check"
                , D.fromChars "out"
                , D.cyan (D.fromChars (D.makeLink "init"))
                , D.fromChars "for"
                , D.fromChars "all"
                , D.fromChars "the"
                , D.fromChars "answers!"
                ]
            :: question
        )



-- ====== INIT ======


type alias InitEnv =
    { cache : Stuff.PackageCache
    , connection : Solver.Connection
    , registry : Registry.Registry
    }


type alias InitDetails =
    { details : Dict ( String, String ) Pkg.Name Solver.Details
    , testDetails : Dict ( String, String ) Pkg.Name Solver.Details
    }


init : Bool -> Task Never (Result Exit.Init ())
init package =
    Solver.initEnv
        |> Task.andThen (initWithEnv package)


initWithEnv : Bool -> Result Exit.RegistryProblem Solver.Env -> Task Never (Result Exit.Init ())
initWithEnv package eitherEnv =
    case eitherEnv of
        Err problem ->
            Task.succeed (Err (Exit.InitRegistryProblem problem))

        Ok (Solver.Env solverEnv) ->
            let
                env =
                    InitEnv solverEnv.cache solverEnv.connection solverEnv.registry
            in
            verify env.cache env.connection env.registry defaults
                |> Task.andThen (verifyTestDefaults env package)


verifyTestDefaults : InitEnv -> Bool -> Solver.SolverResult (Dict ( String, String ) Pkg.Name Solver.Details) -> Task Never (Result Exit.Init ())
verifyTestDefaults env package result =
    case result of
        Solver.SolverErr exit ->
            Task.succeed (Err (Exit.InitSolverProblem exit))

        Solver.NoSolution ->
            Task.succeed (Err (Exit.InitNoSolution (Dict.keys compare defaults)))

        Solver.NoOfflineSolution ->
            Task.succeed (Err (Exit.InitNoOfflineSolution (Dict.keys compare defaults)))

        Solver.SolverOk details ->
            verify env.cache env.connection env.registry testDefaults
                |> Task.andThen (createProjectFiles package details)


createProjectFiles : Bool -> Dict ( String, String ) Pkg.Name Solver.Details -> Solver.SolverResult (Dict ( String, String ) Pkg.Name Solver.Details) -> Task Never (Result Exit.Init ())
createProjectFiles package details result =
    case result of
        Solver.SolverErr exit ->
            Task.succeed (Err (Exit.InitSolverProblem exit))

        Solver.NoSolution ->
            Task.succeed (Err (Exit.InitNoSolution (Dict.keys compare testDefaults)))

        Solver.NoOfflineSolution ->
            Task.succeed (Err (Exit.InitNoOfflineSolution (Dict.keys compare testDefaults)))

        Solver.SolverOk testDetails ->
            Utils.dirCreateDirectoryIfMissing True "src"
                |> Task.andThen (\_ -> Utils.dirCreateDirectoryIfMissing True "tests")
                |> Task.andThen (\_ -> File.writeUtf8 "tests/Example.elm" testExample)
                |> Task.andThen (\_ -> writeOutline package (InitDetails details testDetails))
                |> Task.andThen (\_ -> IO.putStrLn "Okay, I created it. Now read that link!")
                |> Task.map (\_ -> Ok ())


writeOutline : Bool -> InitDetails -> Task Never ()
writeOutline package initDetails =
    let
        outline =
            if package then
                buildPackageOutline initDetails

            else
                buildAppOutline initDetails
    in
    Outline.write "." outline


buildPackageOutline : InitDetails -> Outline.Outline
buildPackageOutline initDetails =
    let
        directs : Dict ( String, String ) Pkg.Name Con.Constraint
        directs =
            Dict.map
                (\pkg _ ->
                    let
                        (Solver.Details vsn _) =
                            Utils.find identity pkg initDetails.details
                    in
                    Con.untilNextMajor vsn
                )
                packageDefaults

        testDirects : Dict ( String, String ) Pkg.Name Con.Constraint
        testDirects =
            Dict.map
                (\pkg _ ->
                    let
                        (Solver.Details vsn _) =
                            Utils.find identity pkg initDetails.testDetails
                    in
                    Con.untilNextMajor vsn
                )
                packageTestDefaults
    in
    Outline.Pkg <|
        Outline.PkgOutline
            { name = Pkg.dummyName
            , summary = Outline.defaultSummary
            , license = Licenses.bsd3
            , version = V.one
            , exposed = Outline.ExposedList []
            , deps = directs
            , testDeps = testDirects
            , elm = Con.defaultElm
            }


buildAppOutline : InitDetails -> Outline.Outline
buildAppOutline initDetails =
    let
        solution : Dict ( String, String ) Pkg.Name V.Version
        solution =
            Dict.map (\_ (Solver.Details vsn _) -> vsn) initDetails.details

        directs : Dict ( String, String ) Pkg.Name V.Version
        directs =
            Dict.intersection compare solution defaults

        indirects : Dict ( String, String ) Pkg.Name V.Version
        indirects =
            Dict.diff solution defaults

        testSolution : Dict ( String, String ) Pkg.Name V.Version
        testSolution =
            Dict.map (\_ (Solver.Details vsn _) -> vsn) initDetails.testDetails

        testDirects : Dict ( String, String ) Pkg.Name V.Version
        testDirects =
            Dict.intersection compare testSolution testDefaults

        testIndirects : Dict ( String, String ) Pkg.Name V.Version
        testIndirects =
            Dict.diff testSolution testDefaults
                |> flip Dict.diff directs
                |> flip Dict.diff indirects
    in
    Outline.App <|
        Outline.AppOutline
            { elm = V.elmCompiler
            , srcDirs = NE.Nonempty (Outline.RelativeSrcDir "src") []
            , depsDirect = directs
            , depsIndirect = indirects
            , testDirect = testDirects
            , testIndirect = testIndirects
            }


verify :
    Stuff.PackageCache
    -> Solver.Connection
    -> Registry.Registry
    -> Dict ( String, String ) Pkg.Name Con.Constraint
    -> Task Never (Solver.SolverResult (Dict ( String, String ) Pkg.Name Solver.Details))
verify cache connection registry constraints =
    Solver.verify cache connection registry constraints


defaults : Dict ( String, String ) Pkg.Name Con.Constraint
defaults =
    Dict.fromList identity
        [ ( Pkg.core, Con.anything )
        , ( Pkg.browser, Con.anything )
        , ( Pkg.html, Con.anything )
        ]


testDefaults : Dict ( String, String ) Pkg.Name Con.Constraint
testDefaults =
    Dict.fromList identity
        [ ( Pkg.test, Con.anything )
        ]


packageDefaults : Dict ( String, String ) Pkg.Name Con.Constraint
packageDefaults =
    Dict.fromList identity
        [ ( Pkg.core, Con.anything )
        ]


packageTestDefaults : Dict ( String, String ) Pkg.Name Con.Constraint
packageTestDefaults =
    Dict.fromList identity
        [ ( Pkg.test, Con.anything )
        ]


testExample : String
testExample =
    """module Example exposing (..)

import Expect exposing (Expectation)
import Fuzz exposing (Fuzzer, int, list, string)
import Test exposing (..)


suite : Test
suite =
    todo "Implement our first test. See https://package.elm-lang.org/packages/elm-explorations/test/latest for how to do this!"
"""
