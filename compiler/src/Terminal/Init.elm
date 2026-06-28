module Terminal.Init exposing
    ( run
    , Flags(..)
    )

{-| Project initialization command for creating new Elm projects.

This module implements the `init` command which scaffolds a new Elm project by
creating an elm.json configuration file, a `src` directory, and a starter
`src/Main.elm` module that compiles immediately. It supports both application and
package project types.


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
import Dict exposing (Dict)
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

Creates an elm.json file with default dependencies, a `src` directory, and a
starter `src/Main.elm` module so the project compiles right away. Supports both
application and package projects.

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
        IO.printLn "Okay, I did not make any changes!"
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
    { details : Dict Pkg.Name Solver.Details
    , testDetails : Dict Pkg.Name Solver.Details
    }


init : Bool -> Task Never (Result Exit.Init ())
init package =
    -- Locate the bundled `eco/kernel` package (next to the executable) so the
    -- dependency solver can resolve it: the scaffolded application depends on it
    -- for console IO, and it ships with eco rather than the package registry.
    Stuff.resolveBundledKernel Nothing
        |> Task.andThen (Solver.initEnv Registry.Normal)
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


verifyTestDefaults : InitEnv -> Bool -> Solver.SolverResult (Dict Pkg.Name Solver.Details) -> Task Never (Result Exit.Init ())
verifyTestDefaults env package result =
    case result of
        Solver.SolverErr exit ->
            Task.succeed (Err (Exit.InitSolverProblem exit))

        Solver.NoSolution ->
            Task.succeed (Err (Exit.InitNoSolution (Dict.keys defaults)))

        Solver.NoOfflineSolution ->
            Task.succeed (Err (Exit.InitNoOfflineSolution (Dict.keys defaults)))

        Solver.SolverOk details ->
            verify env.cache env.connection env.registry testDefaults
                |> Task.andThen (createProjectFiles package details)


createProjectFiles : Bool -> Dict Pkg.Name Solver.Details -> Solver.SolverResult (Dict Pkg.Name Solver.Details) -> Task Never (Result Exit.Init ())
createProjectFiles package details result =
    case result of
        Solver.SolverErr exit ->
            Task.succeed (Err (Exit.InitSolverProblem exit))

        Solver.NoSolution ->
            Task.succeed (Err (Exit.InitNoSolution (Dict.keys testDefaults)))

        Solver.NoOfflineSolution ->
            Task.succeed (Err (Exit.InitNoOfflineSolution (Dict.keys testDefaults)))

        Solver.SolverOk testDetails ->
            Utils.dirCreateDirectoryIfMissing True "src"
                |> Task.andThen (\_ -> writeStarterModule package)
                |> Task.andThen (\_ -> writeOutline package (InitDetails details testDetails))
                |> Task.andThen (\_ -> IO.printLn "Okay, I created it. Now read that link!")
                |> Task.map (\_ -> Ok ())


{-| Write a starter `src/Main.elm` so the freshly created project compiles right
away with `eco make src/Main.elm`. If the file already exists it is left
untouched, so re-running `init` over a partially set-up project is safe.
-}
writeStarterModule : Bool -> Task Never ()
writeStarterModule package =
    Utils.dirDoesFileExist "src/Main.elm"
        |> Task.andThen
            (\exists ->
                if exists then
                    Task.succeed ()

                else
                    File.writeUtf8 "src/Main.elm"
                        (if package then
                            packageExample

                         else
                            appExample
                        )
            )


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
        directs : Dict Pkg.Name Con.Constraint
        directs =
            Dict.map
                (\pkg _ ->
                    let
                        (Solver.Details vsn _) =
                            Utils.dictFind pkg initDetails.details
                    in
                    Con.untilNextMajor vsn
                )
                packageDefaults

        testDirects : Dict Pkg.Name Con.Constraint
        testDirects =
            Dict.map
                (\pkg _ ->
                    let
                        (Solver.Details vsn _) =
                            Utils.dictFind pkg initDetails.testDetails
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
            , exposed = Outline.ExposedList [ "Main" ]
            , deps = directs
            , testDeps = testDirects
            , elm = Con.defaultElm
            }


buildAppOutline : InitDetails -> Outline.Outline
buildAppOutline initDetails =
    let
        solution : Dict Pkg.Name V.Version
        solution =
            Dict.map (\_ (Solver.Details vsn _) -> vsn) initDetails.details

        directs : Dict Pkg.Name V.Version
        directs =
            Dict.filter (\k _ -> Dict.member k defaults) solution

        indirects : Dict Pkg.Name V.Version
        indirects =
            Dict.filter (\k _ -> not (Dict.member k defaults)) solution

        testSolution : Dict Pkg.Name V.Version
        testSolution =
            Dict.map (\_ (Solver.Details vsn _) -> vsn) initDetails.testDetails

        testDirects : Dict Pkg.Name V.Version
        testDirects =
            Dict.filter (\k _ -> Dict.member k testDefaults) testSolution

        testIndirects : Dict Pkg.Name V.Version
        testIndirects =
            Dict.filter (\k _ -> not (Dict.member k testDefaults)) testSolution
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
    -> Dict Pkg.Name Con.Constraint
    -> Task Never (Solver.SolverResult (Dict Pkg.Name Solver.Details))
verify cache connection registry constraints =
    Solver.verify cache connection registry constraints


{-| Default direct dependencies for a new application. eco is geared toward CLI
and server-side programs, so the scaffold is a console app: `eco/kernel` (bundled
with eco) provides the IO primitives and `elm/core` provides `Platform.worker`,
`Task`, and friends. A browser app can add `elm/browser`/`elm/html` with
`eco install`.
-}
defaults : Dict Pkg.Name Con.Constraint
defaults =
    Dict.fromList
        [ ( Pkg.ecoKernel, Con.anything )
        , ( Pkg.core, Con.anything )
        ]


{-| No test dependencies are scaffolded. The usual choice, `elm-explorations/test`,
relies on JavaScript kernel modules (`Elm.Kernel.Test`, `Elm.Kernel.HtmlAsJson`)
that eco cannot compile, so including it would leave the new project unable to
build. Test scaffolding can be added once an eco-compatible test package exists.
-}
testDefaults : Dict Pkg.Name Con.Constraint
testDefaults =
    Dict.empty


packageDefaults : Dict Pkg.Name Con.Constraint
packageDefaults =
    Dict.fromList
        [ ( Pkg.core, Con.anything )
        ]


packageTestDefaults : Dict Pkg.Name Con.Constraint
packageTestDefaults =
    Dict.empty


{-| Starter module for an application project: a "Hello World!" console program.
It uses the Task-based `Eco.Console.write` (not the side-effecting `Eco.Console.log`)
so output flows through the normal command/Task machinery, and only needs the
default dependencies (`eco/kernel`, `elm/core`) so `eco make src/Main.elm`
succeeds immediately.
-}
appExample : String
appExample =
    """module Main exposing (main)

import Eco.Console
import Platform
import Task


type alias Model =
    {}


type Msg
    = Done


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = subscriptions
        }


init : () -> ( Model, Cmd Msg )
init _ =
    ( {}
    , Task.attempt (always Done) (Eco.Console.write Eco.Console.stdout "Hello World!\\n")
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update _ model =
    ( model, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.none
"""


{-| Starter module for a package project: a single exposed value so the package
has at least one exposed module and builds out of the box.
-}
packageExample : String
packageExample =
    """module Main exposing (hello)

{-| Starter module for your package.

@docs hello

-}


{-| A friendly greeting.
-}
hello : String
hello =
    "Hello!"
"""
