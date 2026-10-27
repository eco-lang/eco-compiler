module API.Make exposing (run, Flags(..))

{-| Compiles one Elm file for a caller that wants the result back as a value
rather than as a file on disk.

`run` builds the file in the project around the current directory and returns
a single HTML page as a string: the generated JavaScript, wrapped by
`Compiler.Generate.Html.sandwich` so that the page starts the program in the
one module that defines `main`. The JavaScript back end is the only one used
here, and HTML is the only output.

Not every failure comes back as an `Exit.Make` error. A build in which no
module defines `main`, or more than one does, crashes the process instead.

-}

import Builder.BackgroundWriter as BW
import Builder.Build as Build
import Builder.Deps.Registry as Registry
import Builder.Eco.FEStats as FEStats
import Builder.Elm.Details as Details
import Builder.Generate as Generate
import Builder.Reporting as Reporting
import Builder.Reporting.Exit as Exit
import Builder.Stuff as Stuff
import Compiler.AST.Optimized as Opt
import Compiler.Data.NonEmptyList as NE
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Generate.CodeGen as CodeGen
import Compiler.Generate.Html as Html
import Maybe.Extra as Maybe
import System.IO exposing (FilePath)
import Task exposing (Task)
import Utils.Crash exposing (crash)
import Utils.Task.Extra as Task



-- ====== FLAGS ======


{-| The options of one build, in the order debug, optimize, source maps.

Debug and optimize may not both be `True`; `run` reports that combination as
`Exit.MakeCannotOptimizeAndDebug`. Neither set gives the development mode.
The source maps flag is passed through to the code generator.

-}
type Flags
    = Flags Bool Bool Bool



-- ====== RUN ======


{-| Builds the Elm file at `path` with `flags` and returns the HTML page that
runs it.

The project root is the nearest directory at or above the current directory
holding an `elm.json`; with none the result is `Err Exit.MakeNoOutline`. A build
with no `main`, or with more than one, crashes rather than returning `Err`.

-}
run : String -> Flags -> Task Never (Result Exit.Make String)
run path flags =
    Stuff.findRoot
        |> Task.andThen
            (\maybeRoot ->
                case maybeRoot of
                    Just root ->
                        runHelp root path flags

                    Nothing ->
                        Task.succeed (Err Exit.MakeNoOutline)
            )


{-| Builds `path` in the project at `root` while holding the project's lock,
loading the project details with JSON-style reporting and then generating the
page for the single module that defines `main`. It crashes when there is no
such module or several.
-}
runHelp : String -> String -> Flags -> Task Never (Result Exit.Make String)
runHelp root path (Flags debug optimize withSourceMaps) =
    BW.withScope
        (\scope ->
            Stuff.withRootLock root <|
                Task.run <|
                    (getMode debug optimize
                        |> Task.andThen
                            (\desiredMode ->
                                let
                                    style : Reporting.Style
                                    style =
                                        Reporting.json
                                in
                                Task.eio Exit.MakeBadDetails (Stuff.resolveBundledPackages [] |> Task.andThen (\locals -> Details.load style scope root Nothing Nothing False False locals Registry.Normal))
                                    |> Task.andThen
                                        (\details ->
                                            buildPaths style root details (NE.Nonempty path [])
                                                |> Task.andThen
                                                    (\artifacts ->
                                                        case getMains artifacts of
                                                            [] ->
                                                                crash "No main!"

                                                            [ name ] ->
                                                                toBuilder withSourceMaps Html.leadingLines root details desiredMode artifacts
                                                                    |> Task.map (Html.sandwich name)

                                                            _ ->
                                                                crash "TODO"
                                                    )
                                        )
                            )
                    )
        )



-- ====== GET INFORMATION ======


{-| Returns the generation mode for the debug and optimize flags, failing with
`Exit.MakeCannotOptimizeAndDebug` when both are set.
-}
getMode : Bool -> Bool -> Task Exit.Make DesiredMode
getMode debug optimize =
    case ( debug, optimize ) of
        ( True, True ) ->
            Task.throw Exit.MakeCannotOptimizeAndDebug

        ( True, False ) ->
            Task.succeed Debug

        ( False, False ) ->
            Task.succeed Dev

        ( False, True ) ->
            Task.succeed Prod



-- ====== BUILD PROJECTS ======


{-| Compiles `paths` in the project at `root`, with no build dir, untyped and
with statistics disabled.
-}
buildPaths : Reporting.Style -> FilePath -> Details.Details -> NE.Nonempty FilePath -> Task Exit.Make Build.Artifacts
buildPaths style root details paths =
    Build.fromPaths style root Nothing Nothing details False FEStats.disabled paths |> Task.eio Exit.MakeCannotBuild



-- ====== GET MAINS ======


{-| Returns the names of the root modules of `artifacts` that define `main`.
-}
getMains : Build.Artifacts -> List ModuleName.Raw
getMains (Build.Artifacts artifactsData) =
    List.filterMap (getMain artifactsData.modules) (NE.toList artifactsData.roots)


{-| Returns the name of `root` if it defines `main`. A root inside the project
is looked up in `modules`; a root outside it is judged by its own graph.
-}
getMain : List Build.Module -> Build.Root -> Maybe ModuleName.Raw
getMain modules root =
    case root of
        Build.Inside name ->
            if List.any (isMain name) modules then
                Just name

            else
                Nothing

        Build.Outside name _ (Opt.LocalGraph maybeMain _ _) _ _ ->
            maybeMain
                |> Maybe.map (\_ -> name)


{-| Tells whether `modul` is the module named `targetName` and defines `main`.
-}
isMain : ModuleName.Raw -> Build.Module -> Bool
isMain targetName modul =
    case modul of
        Build.Fresh name _ (Opt.LocalGraph maybeMain _ _) _ _ ->
            Maybe.isJust maybeMain && name == targetName

        Build.Cached name mainIsDefined _ ->
            mainIsDefined && name == targetName



-- ====== TO BUILDER ======


{-| The kind of JavaScript to generate. `Debug`, `Dev` and `Prod` select
`Builder.Generate.debug`, `dev` and `prod`, whose docstrings say what each
produces.
-}
type DesiredMode
    = Debug
    | Dev
    | Prod


{-| Generates the JavaScript for `artifacts` in `desiredMode` and returns it as
a string. `leadingLines` is the number of lines that will precede the
JavaScript in its output, which the source maps account for.
-}
toBuilder : Bool -> Int -> FilePath -> Details.Details -> DesiredMode -> Build.Artifacts -> Task Exit.Make String
toBuilder withSourceMaps leadingLines root details desiredMode artifacts =
    (case desiredMode of
        Debug ->
            Generate.debug Generate.javascriptBackend withSourceMaps leadingLines root Nothing details artifacts

        Dev ->
            Generate.dev Generate.javascriptBackend withSourceMaps leadingLines root Nothing details artifacts

        Prod ->
            Generate.prod Generate.javascriptBackend withSourceMaps leadingLines root Nothing details artifacts
    )
        |> Task.map CodeGen.outputToString
        |> Task.mapError Exit.MakeBadGenerate



-- ====== PARSERS ======
