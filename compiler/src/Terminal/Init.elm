module Terminal.Init exposing
    ( run
    , Flags(..)
    )

{-| The `eco init` command, which turns an empty directory into a project that
builds straight away.

A project is described by its `elm.json`, the _outline_, which lists the
project's dependencies at versions that work together. A new outline cannot
simply name a few packages: their versions, and for an application every
indirect dependency too, must come from the dependency solver. So most of this
module is a chain of tasks that sets up the solver, solves the default
dependencies, and only then writes files.

The chain refuses to run where an `elm.json` already exists, and otherwise
explains what it will do and asks for confirmation unless `--yes` was given.
It then makes the bundled packages, `eco/kernel` and `eco/system`, visible to
the solver. These ship with eco next to the executable rather than through the
package registry, and are found as `Builder.Stuff.resolveBundledPackages`
describes. It solves the application defaults and then the test defaults, which
are empty, creates `src/`, writes a starter `src/Main.elm` unless one exists,
and writes the outline.

An application outline names the defaults as direct dependencies at their solved
versions and every other solved package as indirect. A package outline names
only `elm/core`, with a constraint from its solved version up to the next major
version, under the placeholder name `author/project` at version 1.0.0.


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


{-| The command-line flags of `init`.

The first `Bool` asks for a package rather than an application. The second
skips the confirmation question; the explanation is still printed.

-}
type Flags
    = Flags Bool Bool


{-| Runs `eco init` in the current directory, as the module documentation
describes, and on failure reports the error and exits with failure.
-}
run : () -> Flags -> Task Never ()
run () (Flags package autoYes) =
    Reporting.attempt Exit.initToReport <|
        (Utils.dirDoesFileExist "elm.json"
            |> Task.andThen (checkExistsAndAsk package autoYes)
        )


{-| Fails with `InitAlreadyExists` when `exists` says an `elm.json` is
present, and otherwise asks for confirmation and proceeds as the answer says.
-}
checkExistsAndAsk : Bool -> Bool -> Bool -> Task Never (Result Exit.Init ())
checkExistsAndAsk package autoYes exists =
    if exists then
        Task.succeed (Err Exit.InitAlreadyExists)

    else
        askInitQuestion autoYes
            |> Task.andThen (handleInitApproval package)


{-| Prints the explanation and returns whether to go ahead. With `autoYes` the
explanation is printed without a question and the answer is yes; otherwise the
user is asked as `Builder.Reporting.ask` describes.
-}
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


{-| Creates the project when `approved`, and otherwise prints that nothing was
changed and succeeds.
-}
handleInitApproval : Bool -> Bool -> Task Never (Result Exit.Init ())
handleInitApproval package approved =
    if approved then
        init package

    else
        IO.printLn "Okay, I did not make any changes!"
            |> Task.map (\_ -> Ok ())


{-| Builds the explanation shown before creating a project, with `question`
appended as its last lines.
-}
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


{-| The parts of the solver environment that solving the defaults needs.
-}
type alias InitEnv =
    { cache : Stuff.PackageCache
    , connection : Solver.Connection
    , registry : Registry.Registry
    }


{-| The solutions for the default dependencies and for the test defaults, each
covering indirect dependencies too.
-}
type alias InitDetails =
    { details : Dict Pkg.Name Solver.Details
    , testDetails : Dict Pkg.Name Solver.Details
    }


{-| Creates the project, a package when `package` is `True`, after making the
bundled packages visible to the solver and setting up its environment.
-}
init : Bool -> Task Never (Result Exit.Init ())
init package =
    Stuff.resolveBundledPackages []
        |> Task.andThen (Solver.initEnv Registry.Normal)
        |> Task.andThen (initWithEnv package)


{-| Solves the defaults of the project kind (`packageDefaults` for a package,
`defaults` for an application) in the environment `eitherEnv`, or fails with
the registry problem that kept it from being set up.
-}
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
            verify env.cache env.connection env.registry (defaultsFor package)
                |> Task.andThen (verifyTestDefaults env package)


{-| Turns a failed solution of the defaults into an `Exit.Init` error naming
them, and on success solves the test defaults.
-}
verifyTestDefaults : InitEnv -> Bool -> Solver.SolverResult (Dict Pkg.Name Solver.Details) -> Task Never (Result Exit.Init ())
verifyTestDefaults env package result =
    case result of
        Solver.SolverErr exit ->
            Task.succeed (Err (Exit.InitSolverProblem exit))

        Solver.NoSolution ->
            Task.succeed (Err (Exit.InitNoSolution (Dict.keys (defaultsFor package))))

        Solver.NoOfflineSolution ->
            Task.succeed (Err (Exit.InitNoOfflineSolution (Dict.keys (defaultsFor package))))

        Solver.SolverOk details ->
            verify env.cache env.connection env.registry testDefaults
                |> Task.andThen (createProjectFiles package details)


{-| Turns a failed solution of the test defaults into an `Exit.Init` error
naming them, and on success creates `src/`, the starter module and the outline,
given `details`, the solution of the defaults.
-}
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


{-| Writes the starter module for a package or an application to
`src/Main.elm`, leaving an existing file there untouched.
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


{-| Writes `elm.json` in the current directory: a package outline when
`package` is `True`, otherwise an application outline.
-}
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


{-| Builds a package outline whose dependencies are `packageDefaults` and
`packageTestDefaults`, each constrained from its solved version up to the next
major version. It crashes if a package default is missing from its solution.
-}
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


{-| Builds an application outline from the two solutions: the defaults are
direct dependencies and every other solved package is indirect, and likewise for
the test solution, whose indirect dependencies leave out packages already among
the main dependencies.
-}
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


{-| Solves `constraints`, as `Builder.Deps.Solver.verify` does.
-}
verify :
    Stuff.PackageCache
    -> Solver.Connection
    -> Registry.Registry
    -> Dict Pkg.Name Con.Constraint
    -> Task Never (Solver.SolverResult (Dict Pkg.Name Solver.Details))
verify cache connection registry constraints =
    Solver.verify cache connection registry constraints


{-| The direct dependencies a new project's solution starts from: `packageDefaults`
for a package, `defaults` for an application.
-}
defaultsFor : Bool -> Dict Pkg.Name Con.Constraint
defaultsFor package =
    if package then
        packageDefaults

    else
        defaults


{-| The direct dependencies of a new application, any version of each:
`eco/system`, which the starter application module imports, and `elm/core`.
`eco/kernel` is not among them.
-}
defaults : Dict Pkg.Name Con.Constraint
defaults =
    Dict.fromList
        [ ( Pkg.ecoSystem, Con.anything )
        , ( Pkg.core, Con.anything )
        ]


{-| The test dependencies of a new application, which are none.
`elm-explorations/test` is not included because it relies on JavaScript kernel
modules that eco cannot compile, so the new project would not build.
-}
testDefaults : Dict Pkg.Name Con.Constraint
testDefaults =
    Dict.empty


{-| The direct dependencies of a new package: `elm/core`, any version.
-}
packageDefaults : Dict Pkg.Name Con.Constraint
packageDefaults =
    Dict.fromList
        [ ( Pkg.core, Con.anything )
        ]


{-| The test dependencies of a new package, which are none.
-}
packageTestDefaults : Dict Pkg.Name Con.Constraint
packageTestDefaults =
    Dict.empty


{-| The source of the starter `Main` module for an application: a program,
built with `eco/system`, that writes "Hello World!" to standard output. It
imports only modules of the default dependencies.
-}
appExample : String
appExample =
    """module Main exposing (main)

import Stream
import System


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram
        (\\env -> Stream.logLine "Hello World!" env.stdout)
"""


{-| The source of the starter `Main` module for a package, the module the
package outline exposes. It exposes one documented string, `hello`.
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
