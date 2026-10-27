module Terminal.Make exposing
    ( run
    , Flags(..), FlagsData, Output, ReportType
    , output, reportType, docsFile
    , parseOutput, parseReportType, parseDocsFile
    , buildDir, parseBuildDir
    , configFlag, parseConfig
    , kernelPackage, parseKernelPackage
    , localPackage, parseLocalPackage
    )

{-| The `eco make` command: it compiles a project's Elm code and writes the
output the flags ask for.

What is built depends on whether any files are named. With none, the project
must be a package, and its exposed modules are built, with their documentation
written to the `--docs` file when one is given. With files named, those files
are the roots of the build, and the result is written in the form `--output`
selects.

The output form is decided by the output file's name alone (see
`parseOutput`). A `.js` file gets JavaScript, a `.html` file a page that runs
one program, and a `.mlir` file MLIR, written as bytecode unless `--text-mlir`
is given. A null device gets nothing, and any other name is a native
executable. With no `--output`, one root that defines `main` gives
`index.html`, several give `elm.js`, and none give nothing.

MLIR and native output take the _typed path_: the front end keeps types through
optimization, which the MLIR back end needs and JavaScript output does not. A
native executable is made by writing MLIR to a temporary file inside the
project's `eco-stuff` directory and handing that file to
`Eco.NativeDriver.lowerAndLink`.

A _build dir_ is a name, given with `--builddir`, for a subdirectory of
`eco-stuff` with its own caches and lock, so that separate builds of one
project can run side by side. The whole build runs holding that directory's
lock, as `Builder.Stuff.withRootLockBuildDir` describes.

Most of the file is the chain of steps from the flags to a finished build, and
the parsers for the flags' values.


# Command Entry

@docs run


# Configuration Types

@docs Flags, FlagsData, Output, ReportType


# Parser Definitions

@docs output, reportType, docsFile


# Parser Functions

@docs parseOutput, parseReportType, parseDocsFile


# Build Directory

@docs buildDir, parseBuildDir
@docs configFlag, parseConfig


# Kernel and Local Packages

@docs kernelPackage, parseKernelPackage
@docs localPackage, parseLocalPackage

-}

import Builder.BackgroundWriter as BW
import Builder.Build as Build
import Builder.Deps.Registry as Registry
import Builder.Eco.Config as EcoConfigLoader
import Builder.Eco.FEStats as FEStats
import Builder.Elm.Details as Details
import Builder.File as File
import Builder.GcPoints as GcPoints
import Builder.Generate as Generate
import Builder.Reporting as Reporting
import Builder.Reporting.Exit as Exit
import Builder.Stuff as Stuff
import Compiler.AST.Optimized as Opt
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)
import Compiler.Data.NonEmptyList as NE
import Compiler.Eco.Config as Config
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Generate.CodeGen as CodeGen
import Compiler.Generate.Html as Html
import Eco.NativeDriver
import Maybe.Extra as Maybe
import System.IO exposing (FilePath)
import Task exposing (Task)
import Terminal.Terminal.Internal exposing (Parser(..))
import Utils.Main as Utils
import Utils.Task.Extra as Task



-- ====== FLAGS ======


{-| Every flag of the `make` command, as parsed from the command line.

`docs` is only used when no files are named, since only a package build writes
documentation. `localPackage` holds the `--local-package` mappings, each from a
package name to the directory the package is read from.

-}
type alias FlagsData =
    { debug : Bool
    , optimize : Bool
    , withSourceMaps : Bool
    , output : Maybe Output
    , report : Maybe ReportType
    , docs : Maybe String
    , showPackageErrors : Bool
    , buildDir : Maybe String
    , kernelPackage : Maybe Pkg.Name
    , localPackage : List ( Pkg.Name, FilePath )
    , textMlir : Bool
    , refreshRegistry : Bool
    , configPath : Maybe String
    , stats : Bool
    , noCache : Bool
    }


{-| The flags of the `make` command, as `run` takes them.
-}
type Flags
    = Flags FlagsData


{-| What a build writes, and where.

`JS`, `Html` and `MLIR` carry the file to write. `MLIR` is written as bytecode
unless `--text-mlir` is given.

`ELF` carries the path of the native executable to write. Despite the name, the
kind of file is whatever `Eco.NativeDriver.lowerAndLink` makes of that path.

`DevNull` builds and writes nothing.

-}
type Output
    = JS String
    | Html String
    | MLIR String
    | ELF String
    | DevNull


{-| A machine-readable style for reporting errors, chosen with `--report`.
Without one, errors are reported in the terminal layout.

`Json` reports an error as JSON.

-}
type ReportType
    = Json



-- ====== RUN ======


{-| Runs `eco make` on `paths` with `flags`, as the module docstring describes.
An error is reported and ends the process with failure. When `--stats` is on,
front-end statistics are printed once the build is done.
-}
run : List String -> Flags -> Task Never ()
run paths ((Flags flagsData) as flags) =
    FEStats.init flagsData.stats
        |> Task.andThen
            (\stats ->
                getStyle flagsData.report
                    |> Task.andThen (runWithStyle paths flags stats)
                    |> Task.andThen (\_ -> FEStats.finalize stats)
                    |> Task.andThen (\_ -> FEStats.prettyPrint stats)
            )


{-| Finds the project root and runs the build from it.
-}
runWithStyle : List String -> Flags -> FEStats.Handle -> Reporting.Style -> Task Never ()
runWithStyle paths flags stats style =
    Stuff.findRoot
        |> Task.andThen (runWithRoot paths flags stats style)


{-| Runs the build from `maybeRoot`, reporting `MakeNoOutline` when no project
root was found, and reports any build error in `style`.
-}
runWithRoot : List String -> Flags -> FEStats.Handle -> Reporting.Style -> Maybe FilePath -> Task Never ()
runWithRoot paths flags stats style maybeRoot =
    Reporting.attemptWithStyle style Exit.makeToReport <|
        case maybeRoot of
            Just root ->
                runHelp root paths style stats flags

            Nothing ->
                Task.succeed (Err Exit.MakeNoOutline)


{-| The kind of JavaScript to generate: `Debug` with `--debug`, `Prod` with
`--optimize`, and `Dev` with neither.
-}
type DesiredMode
    = Debug
    | Dev
    | Prod


{-| Everything about the build that the output step needs once the files are
built.
-}
type alias BuildContext =
    { root : FilePath
    , style : Reporting.Style
    , withSourceMaps : Bool
    , maybeOutput : Maybe Output
    , maybeDocs : Maybe FilePath
    , maybeBuildDir : Maybe String
    , desiredMode : DesiredMode
    , details : Details.Details
    , localPackage : List ( Pkg.Name, FilePath )
    , textMlir : Bool
    , ecoConfig : Config.EcoConfig
    , stats : FEStats.Handle
    }


{-| Builds `paths` from the project at `root`, with each bundled package that is
found and not already mapped added to the `--local-package` mappings, inside a
background-writer scope.
-}
runHelp : String -> List String -> Reporting.Style -> FEStats.Handle -> Flags -> Task Never (Result Exit.Make ())
runHelp root paths style stats (Flags flagsData) =
    let
        registryPolicy =
            if flagsData.refreshRegistry then
                Registry.ForceRefresh

            else
                Registry.Normal
    in
    Stuff.resolveBundledPackages flagsData.localPackage
        |> Task.andThen
            (\localPackages ->
                BW.withScope (runHelpWithScope root paths style stats flagsData.noCache flagsData.debug flagsData.optimize flagsData.withSourceMaps flagsData.output flagsData.docs flagsData.showPackageErrors flagsData.buildDir flagsData.kernelPackage localPackages flagsData.textMlir flagsData.configPath registryPolicy)
            )


{-| Builds while holding the lock of the build dir, after checking that
`--debug` and `--optimize` are not both given.
-}
runHelpWithScope : FilePath -> List String -> Reporting.Style -> FEStats.Handle -> Bool -> Bool -> Bool -> Bool -> Maybe Output -> Maybe FilePath -> Bool -> Maybe String -> Maybe Pkg.Name -> List ( Pkg.Name, FilePath ) -> Bool -> Maybe String -> Registry.RegistryPolicy -> BW.Scope -> Task Never (Result Exit.Make ())
runHelpWithScope root paths style stats noCache debug optimize withSourceMaps maybeOutput maybeDocs showPackageErrors maybeBuildDir maybeKernelPackage localPackages textMlir maybeConfigPath registryPolicy scope =
    Stuff.withRootLockBuildDir root
        maybeBuildDir
        (Task.run
            (getMode debug optimize
                |> Task.andThen (loadDetailsAndBuild root paths style stats noCache withSourceMaps maybeOutput maybeDocs showPackageErrors maybeBuildDir maybeKernelPackage localPackages textMlir maybeConfigPath registryPolicy scope)
            )
        )


{-| Loads the eco config and the project details, then builds.
-}
loadDetailsAndBuild : FilePath -> List String -> Reporting.Style -> FEStats.Handle -> Bool -> Bool -> Maybe Output -> Maybe FilePath -> Bool -> Maybe String -> Maybe Pkg.Name -> List ( Pkg.Name, FilePath ) -> Bool -> Maybe String -> Registry.RegistryPolicy -> BW.Scope -> DesiredMode -> Task Exit.Make ()
loadDetailsAndBuild root paths style stats noCache withSourceMaps maybeOutput maybeDocs showPackageErrors maybeBuildDir maybeKernelPackage localPackages textMlir maybeConfigPath registryPolicy scope desiredMode =
    EcoConfigLoader.load maybeConfigPath root
        |> Task.andThen
            (\ecoConfig ->
                FEStats.withPhase stats
                    FEStats.PhaseDeps
                    (Task.eio Exit.MakeBadDetails (Details.load style scope root maybeBuildDir (Just (Config.hash ecoConfig)) (shouldUseTypedOpt maybeOutput) showPackageErrors localPackages registryPolicy))
                    |> Task.andThen (buildWithDetails root paths style stats noCache withSourceMaps maybeOutput maybeDocs maybeBuildDir maybeKernelPackage localPackages textMlir ecoConfig desiredMode)
            )


{-| Builds the package's exposed modules when `paths` is empty, and otherwise
builds `paths` and writes the output.
-}
buildWithDetails : FilePath -> List String -> Reporting.Style -> FEStats.Handle -> Bool -> Bool -> Maybe Output -> Maybe FilePath -> Maybe String -> Maybe Pkg.Name -> List ( Pkg.Name, FilePath ) -> Bool -> Config.EcoConfig -> DesiredMode -> Details.Details -> Task Exit.Make ()
buildWithDetails root paths style stats noCache withSourceMaps maybeOutput maybeDocs maybeBuildDir maybeKernelPackage localPackages textMlir ecoConfig desiredMode details =
    let
        ctx : BuildContext
        ctx =
            BuildContext root style withSourceMaps maybeOutput maybeDocs maybeBuildDir desiredMode details localPackages textMlir ecoConfig stats
    in
    case paths of
        [] ->
            getExposed details
                |> Task.andThen (buildExposed style root maybeBuildDir maybeKernelPackage details maybeDocs stats)

        p :: ps ->
            FEStats.withPhase stats FEStats.PhaseLocal (buildPaths noCache style root maybeBuildDir maybeKernelPackage details (shouldUseTypedOpt maybeOutput) stats (NE.Nonempty p ps))
                |> Task.andThen (handleArtifacts ctx)


{-| Tells whether the build takes the typed path, which it does for MLIR and
native output.
-}
shouldUseTypedOpt : Maybe Output -> Bool
shouldUseTypedOpt maybeOutput =
    case maybeOutput of
        Just (MLIR _) ->
            True

        Just (ELF _) ->
            True

        _ ->
            False


{-| Writes the output the context asks for from built `artifacts`.
-}
handleArtifacts : BuildContext -> Build.Artifacts -> Task Exit.Make ()
handleArtifacts ctx artifacts =
    case ctx.maybeOutput of
        Nothing ->
            handleDefaultOutput ctx artifacts

        Just DevNull ->
            Task.succeed ()

        Just (JS target) ->
            handleJsOutput ctx target artifacts

        Just (Html target) ->
            handleHtmlOutput ctx target artifacts

        Just (MLIR target) ->
            handleMlirOutput ctx target artifacts

        Just (ELF target) ->
            handleElfOutput ctx target artifacts


{-| Writes the output for a build with no `--output`: `index.html` for one root
that defines `main`, `elm.js` for several, and nothing for none. Roots without
a `main` are left out.
-}
handleDefaultOutput : BuildContext -> Build.Artifacts -> Task Exit.Make ()
handleDefaultOutput ctx artifacts =
    case getMains artifacts of
        [] ->
            Task.succeed ()

        [ name ] ->
            toBuilder Generate.javascriptBackend ctx.withSourceMaps Html.leadingLines ctx.root ctx.maybeBuildDir ctx.details ctx.desiredMode artifacts
                |> Task.andThen (generateHtml ctx.style "index.html" name)

        name :: names ->
            toBuilder Generate.javascriptBackend ctx.withSourceMaps 0 ctx.root ctx.maybeBuildDir ctx.details ctx.desiredMode artifacts
                |> Task.andThen (\builder -> generate ctx.style "elm.js" builder (NE.Nonempty name names))


{-| Writes JavaScript for every root to `target`, failing with
`MakeNonMainFilesIntoJavaScript` when any root does not define `main`.
-}
handleJsOutput : BuildContext -> FilePath -> Build.Artifacts -> Task Exit.Make ()
handleJsOutput ctx target artifacts =
    case getNoMains artifacts of
        [] ->
            let
                rootNames =
                    Build.getRootNames artifacts

                style =
                    ctx.style
            in
            toBuilder Generate.javascriptBackend ctx.withSourceMaps 0 ctx.root ctx.maybeBuildDir ctx.details ctx.desiredMode artifacts
                |> Task.andThen (\builder -> generate style target builder rootNames)

        name :: names ->
            Task.throw (Exit.MakeNonMainFilesIntoJavaScript name names)


{-| Writes an HTML page to `target`, failing unless there is exactly one root
and it defines `main`.
-}
handleHtmlOutput : BuildContext -> FilePath -> Build.Artifacts -> Task Exit.Make ()
handleHtmlOutput ctx target artifacts =
    hasOneMain artifacts
        |> Task.andThen (buildAndGenerateHtml ctx target artifacts)


{-| Generates JavaScript for `artifacts` and writes it to `target` as a page that
runs module `name`.
-}
buildAndGenerateHtml : BuildContext -> FilePath -> Build.Artifacts -> ModuleName.Raw -> Task Exit.Make ()
buildAndGenerateHtml ctx target artifacts name =
    toBuilder Generate.javascriptBackend ctx.withSourceMaps Html.leadingLines ctx.root ctx.maybeBuildDir ctx.details ctx.desiredMode artifacts
        |> Task.andThen (generateHtml ctx.style target name)


{-| Writes `builder`, the generated JavaScript, to `target` inside a page that
runs module `name`.
-}
generateHtml : Reporting.Style -> FilePath -> ModuleName.Raw -> String -> Task Exit.Make ()
generateHtml style target name builder =
    generate style target (Html.sandwich name builder) (NE.Nonempty name [])


{-| Writes MLIR for the program to `target`, as text with `--text-mlir` and as
bytecode otherwise. Fails with `MakeNonMainFilesIntoJavaScript` when any root
does not define `main`.
-}
handleMlirOutput : BuildContext -> FilePath -> Build.Artifacts -> Task Exit.Make ()
handleMlirOutput ctx target artifacts =
    case getNoMains artifacts of
        [] ->
            let
                rootNames =
                    Build.getRootNames artifacts

                -- Bound so the final closure keeps `style` alive, not `ctx`,
                -- whose `details` can hold whole graphs.
                style =
                    ctx.style

                writeTask =
                    if ctx.textMlir then
                        Generate.writeMonoMlirStreaming
                            ctx.ecoConfig
                            ctx.stats
                            ctx.root
                            ctx.maybeBuildDir
                            ctx.localPackage
                            ctx.details
                            artifacts
                            target

                    else
                        Generate.writeMonoMlirStreamingBytecode
                            ctx.ecoConfig
                            ctx.stats
                            ctx.root
                            ctx.maybeBuildDir
                            ctx.localPackage
                            ctx.details
                            artifacts
                            target
            in
            Task.io
                (Utils.dirCreateDirectoryIfMissing True (Utils.fpTakeDirectory target))
                |> Task.andThen (\_ -> writeTask |> Task.mapError Exit.MakeBadGenerate)
                |> Task.andThen
                    (\_ ->
                        Task.io (Reporting.reportGenerate style rootNames target)
                    )

        name :: names ->
            Task.throw (Exit.MakeNonMainFilesIntoJavaScript name names)


{-| Builds a native executable at `target`. Fails with
`MakeNonMainFilesIntoJavaScript` when any root does not define `main`.

The program is written as MLIR, text with `--text-mlir` and bytecode
otherwise, to `eco-<name>.mlir` in the `build` directory of the build dir, or of
the project's stuff directory when no build dir is given, where `<name>` is the
file name of `target`. After the pre-link collection that
`Builder.GcPoints.preLink` describes, that file is handed to
`Eco.NativeDriver.lowerAndLink` along with `target` and the first root's module
name. A failure there is reported as `GenerateNativeDriverError`. The temporary
file is removed only on success, so after a failure it is still there to
reproduce the problem with.

-}
handleElfOutput : BuildContext -> FilePath -> Build.Artifacts -> Task Exit.Make ()
handleElfOutput ctx target artifacts =
    case getNoMains artifacts of
        [] ->
            let
                rootNames =
                    Build.getRootNames artifacts

                -- Bound so the closures pending during the pre-link
                -- collection keep these alive, not `ctx`, whose `details` can
                -- hold whole graphs.
                style =
                    ctx.style

                gcCfg =
                    ctx.ecoConfig.gc

                (NE.Nonempty rootModuleName _) =
                    rootNames

                tempMlirDir : FilePath
                tempMlirDir =
                    Stuff.stuffWithBuildDir ctx.root ctx.maybeBuildDir
                        ++ "/build"

                tempMlirPath : FilePath
                tempMlirPath =
                    tempMlirDir ++ "/eco-" ++ Utils.fpTakeFileName target ++ ".mlir"

                writeMlirTask : Task Exit.Make ()
                writeMlirTask =
                    if ctx.textMlir then
                        Generate.writeMonoMlirStreaming
                            ctx.ecoConfig
                            ctx.stats
                            ctx.root
                            ctx.maybeBuildDir
                            ctx.localPackage
                            ctx.details
                            artifacts
                            tempMlirPath
                            |> Task.mapError Exit.MakeBadGenerate

                    else
                        Generate.writeMonoMlirStreamingBytecode
                            ctx.ecoConfig
                            ctx.stats
                            ctx.root
                            ctx.maybeBuildDir
                            ctx.localPackage
                            ctx.details
                            artifacts
                            tempMlirPath
                            |> Task.mapError Exit.MakeBadGenerate
            in
            Task.io
                (Utils.dirCreateDirectoryIfMissing True
                    (Utils.fpTakeDirectory target)
                )
                |> Task.andThen
                    (\_ ->
                        Task.io
                            (Utils.dirCreateDirectoryIfMissing True tempMlirDir)
                    )
                |> Task.andThen (\_ -> writeMlirTask)
                -- The collection is its own step: the step holding
                -- `writeMlirTask`, and with it `artifacts`, has returned, so
                -- codegen's values are unreachable.
                |> Task.andThen (\_ -> GcPoints.preLink gcCfg)
                |> Task.andThen
                    (\_ ->
                        -- On failure the temporary file is deliberately
                        -- kept, so the lowering can be reproduced from it.
                        Eco.NativeDriver.lowerAndLink tempMlirPath target rootModuleName
                            |> Task.mapError
                                (Exit.MakeBadGenerate << Exit.GenerateNativeDriverError)
                    )
                |> Task.andThen
                    (\_ ->
                        Task.io (Utils.dirRemoveFile tempMlirPath)
                    )
                |> Task.andThen
                    (\_ ->
                        Task.io (Reporting.reportGenerate style rootNames target)
                    )

        name :: names ->
            Task.throw (Exit.MakeNonMainFilesIntoJavaScript name names)



-- ====== GET INFORMATION ======


{-| Returns the reporting style for `--report`: JSON for `Json`, and the
terminal style when none is given.
-}
getStyle : Maybe ReportType -> Task Never Reporting.Style
getStyle report =
    case report of
        Nothing ->
            Reporting.terminal

        Just Json ->
            Task.succeed Reporting.json


{-| Returns the generation mode for `debug` and `optimize`, failing with
`MakeCannotOptimizeAndDebug` when both are set.
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


{-| Returns the exposed modules of a package, failing for an application or a
package that exposes nothing.
-}
getExposed : Details.Details -> Task Exit.Make (NE.Nonempty ModuleName.Raw)
getExposed (Details.Details detailsData) =
    case detailsData.outline of
        Details.ValidApp _ ->
            Task.throw Exit.MakeAppNeedsFileNames

        Details.ValidPkg _ exposed _ ->
            case exposed of
                [] ->
                    Task.throw Exit.MakePkgNeedsExposing

                m :: ms ->
                    Task.succeed (NE.Nonempty m ms)



-- ====== BUILD PROJECTS ======


{-| Builds the package's `exposed` modules, writing documentation to the
`maybeDocs` file when one is given.
-}
buildExposed : Reporting.Style -> FilePath -> Maybe String -> Maybe Pkg.Name -> Details.Details -> Maybe FilePath -> FEStats.Handle -> NE.Nonempty ModuleName.Raw -> Task Exit.Make ()
buildExposed style root maybeBuildDir maybeKernelPackage details maybeDocs stats exposed =
    let
        docsGoal : Build.DocsGoal ()
        docsGoal =
            Maybe.unwrap Build.ignoreDocs Build.writeDocs maybeDocs
    in
    FEStats.withPhase stats FEStats.PhaseLocal <|
        (Task.eio Exit.MakeCannotBuild <|
            Build.fromExposed style
                root
                maybeBuildDir
                maybeKernelPackage
                details
                docsGoal
                stats
                exposed
        )


{-| Builds the files at `paths`. With `noCache` the build writes no caches.
`needsTypedOpt` selects the typed path.
-}
buildPaths : Bool -> Reporting.Style -> FilePath -> Maybe String -> Maybe Pkg.Name -> Details.Details -> Bool -> FEStats.Handle -> NE.Nonempty FilePath -> Task Exit.Make Build.Artifacts
buildPaths noCache style root maybeBuildDir maybeKernelPackage details needsTypedOpt stats paths =
    Build.fromPathsWith
        (if noCache then
            Build.OneShot

         else
            Build.WriteCaches
        )
        style
        root
        maybeBuildDir
        maybeKernelPackage
        details
        needsTypedOpt
        stats
        paths
        |> Task.eio Exit.MakeCannotBuild



-- ====== GET MAINS ======


{-| Returns the module names of the roots that define `main`, in root order.
-}
getMains : Build.Artifacts -> List ModuleName.Raw
getMains (Build.Artifacts artifacts) =
    List.filterMap (getMain artifacts.modules) (NE.toList artifacts.roots)


{-| Returns the module name of `root` when it defines `main`.
-}
getMain : List Build.Module -> Build.Root -> Maybe ModuleName.Raw
getMain modules root =
    case root of
        Build.Inside name ->
            if List.any (isMain name) modules then
                Just name

            else
                Nothing

        Build.Outside name _ objs typed _ ->
            if graphHasMain objs typed then
                Just name

            else
                Nothing


{-| Tells whether `modul` is the module named `targetName` and defines `main`.
-}
isMain : ModuleName.Raw -> Build.Module -> Bool
isMain targetName modul =
    case modul of
        Build.Fresh name _ objs typed _ ->
            graphHasMain objs typed && name == targetName

        Build.Cached name mainIsDefined _ ->
            mainIsDefined && name == targetName



-- ====== HAS ONE MAIN ======


{-| Returns the module name of the only root, failing with
`MakeMultipleFilesIntoHtml` when there are several roots and with `MakeNoMain`
when the one root does not define `main`.
-}
hasOneMain : Build.Artifacts -> Task Exit.Make ModuleName.Raw
hasOneMain (Build.Artifacts artifacts) =
    case artifacts.roots of
        NE.Nonempty root [] ->
            Task.mio Exit.MakeNoMain (Task.succeed <| getMain artifacts.modules root)

        NE.Nonempty _ (_ :: _) ->
            Task.throw Exit.MakeMultipleFilesIntoHtml



-- ====== GET MAINLESS ======


{-| Returns the module names of the roots that do not define `main`, in root
order.
-}
getNoMains : Build.Artifacts -> List ModuleName.Raw
getNoMains (Build.Artifacts artifacts) =
    List.filterMap (getNoMain artifacts.modules) (NE.toList artifacts.roots)


{-| Returns the module name of `root` when it does not define `main`.
-}
getNoMain : List Build.Module -> Build.Root -> Maybe ModuleName.Raw
getNoMain modules root =
    case root of
        Build.Inside name ->
            if List.any (isMain name) modules then
                Nothing

            else
                Just name

        Build.Outside name _ objs typed _ ->
            if graphHasMain objs typed then
                Nothing

            else
                Just name


{-| Tells whether a module compiled in this build defines `main`, given its
erased graph and, on a typed build, its typed graph.

Either graph having a `main` counts. On the typed path the erased graph is the
stub `Compiler.AST.Optimized.typedPathStub` describes, whose `main` only
records that one exists. That marker is what survives a graph being written and
read back, since the typed graph's codec drops `main`.

-}
graphHasMain : Opt.LocalGraph -> Maybe (TOpt.LocalGraph Name) -> Bool
graphHasMain (Opt.LocalGraph maybeMain _ _) maybeTyped =
    case maybeTyped of
        Just (TOpt.LocalGraph data) ->
            Maybe.isJust maybeMain || Maybe.isJust data.main

        Nothing ->
            Maybe.isJust maybeMain



-- ====== GENERATE ======


{-| Writes `builder` to `target`, creating its directory if needed, and reports
that `names` were written there.
-}
generate : Reporting.Style -> FilePath -> String -> NE.Nonempty ModuleName.Raw -> Task Exit.Make ()
generate style target builder names =
    Task.io
        (Utils.dirCreateDirectoryIfMissing True (Utils.fpTakeDirectory target)
            |> Task.andThen (\_ -> File.writeUtf8 target builder)
            |> Task.andThen (\_ -> Reporting.reportGenerate style names target)
        )



-- ====== TO BUILDER ======


{-| Generates JavaScript for `artifacts` in `desiredMode`, as a string.
`leadingLines` is the number of lines that will come before it in the output
file, which source maps need.
-}
toBuilder : CodeGen.CodeGen -> Bool -> Int -> FilePath -> Maybe String -> Details.Details -> DesiredMode -> Build.Artifacts -> Task Exit.Make String
toBuilder backend withSourceMaps leadingLines root maybeBuildDir details desiredMode artifacts =
    (case desiredMode of
        Debug ->
            Generate.debug backend withSourceMaps leadingLines root maybeBuildDir details artifacts

        Dev ->
            Generate.dev backend withSourceMaps leadingLines root maybeBuildDir details artifacts

        Prod ->
            Generate.prod backend withSourceMaps leadingLines root maybeBuildDir details artifacts
    )
        |> Task.map CodeGen.outputToString
        |> Task.mapError Exit.MakeBadGenerate



-- ====== PARSERS ======


{-| The parser for the value of `--report`.
-}
reportType : Parser
reportType =
    Parser
        { singular = "report type"
        , plural = "report types"
        , suggest = \_ -> Task.succeed [ "json" ]
        , examples = \_ -> Task.succeed [ "json" ]
        }


{-| Reads a `--report` value. Only `json` is accepted.
-}
parseReportType : String -> Maybe ReportType
parseReportType string =
    if string == "json" then
        Just Json

    else
        Nothing


{-| The parser for the value of `--output`.
-}
output : Parser
output =
    Parser
        { singular = "output file"
        , plural = "output files"
        , suggest = \_ -> Task.succeed []
        , examples = \_ -> Task.succeed [ "elm.js", "index.html", "output.mlir", "/dev/null" ]
        }


{-| Reads an `--output` value, choosing the output form from the name.

`/dev/null`, `NUL` and `<|null` give `DevNull`. A name ending in `.html`, `.js`
or `.mlir` gives `Html`, `JS` or `MLIR`, provided something comes before the
extension. The empty string is rejected, and every other name gives `ELF`.

-}
parseOutput : String -> Maybe Output
parseOutput name =
    if isDevNull name then
        Just DevNull

    else if hasExt ".html" name then
        Just (Html name)

    else if hasExt ".js" name then
        Just (JS name)

    else if hasExt ".mlir" name then
        Just (MLIR name)

    else if String.isEmpty name then
        Nothing

    else
        Just (ELF name)


{-| The parser for the value of `--docs`.
-}
docsFile : Parser
docsFile =
    Parser
        { singular = "json file"
        , plural = "json files"
        , suggest = \_ -> Task.succeed []
        , examples = \_ -> Task.succeed [ "docs.json", "documentation.json" ]
        }


{-| Reads a `--docs` value, accepting a name that ends in `.json` with something
before the extension.
-}
parseDocsFile : String -> Maybe String
parseDocsFile name =
    if hasExt ".json" name then
        Just name

    else
        Nothing


{-| The parser for the value of `--builddir`.
-}
buildDir : Parser
buildDir =
    Parser
        { singular = "build directory"
        , plural = "build directories"
        , suggest = \_ -> Task.succeed []
        , examples = \_ -> Task.succeed [ "TestName", "MyBuild" ]
        }


{-| Reads a `--builddir` value, accepting any non-empty name with no `/` or `\`.
-}
parseBuildDir : String -> Maybe String
parseBuildDir dir =
    if String.isEmpty dir then
        Nothing

    else if String.contains "/" dir || String.contains "\\" dir then
        Nothing

    else
        Just dir


{-| The parser for the value of `--config`, the path of an eco config file.
-}
configFlag : Parser
configFlag =
    Parser
        { singular = "config file"
        , plural = "config files"
        , suggest = \_ -> Task.succeed []
        , examples = \_ -> Task.succeed [ "eco-config.json", "configs/release.json" ]
        }


{-| Reads a `--config` value, accepting any non-empty path.
-}
parseConfig : String -> Maybe String
parseConfig path =
    if String.isEmpty path then
        Nothing

    else
        Just path


{-| The parser for the value of `--kernel-package`, a package name written
`author/project`.
-}
kernelPackage : Parser
kernelPackage =
    Parser
        { singular = "kernel package"
        , plural = "kernel packages"
        , suggest = \_ -> Task.succeed []
        , examples = \_ -> Task.succeed [ "eco/compiler" ]
        }


{-| Reads a package name written `author/project`. Any string with exactly one
`/` is accepted; neither part is checked against the rules for package names.
-}
parseKernelPackage : String -> Maybe Pkg.Name
parseKernelPackage str =
    case String.split "/" str of
        [ author, name ] ->
            Just ( author, name )

        _ ->
            Nothing


{-| The parser for the value of `--local-package`, written
`author/project=path`. The flag may be repeated, once per package.
-}
localPackage : Parser
localPackage =
    Parser
        { singular = "local package mapping"
        , plural = "local package mappings"
        , suggest = \_ -> Task.succeed []
        , examples = \_ -> Task.succeed [ "eco/kernel=../eco-kernel-cpp" ]
        }


{-| Reads a `--local-package` value written `author/project=path` into the
package name and the path.

The string is split at the first `=` only, so the path may itself contain `=`.
The path must not be empty, and the name is read as `parseKernelPackage` reads
it.

-}
parseLocalPackage : String -> Maybe ( Pkg.Name, FilePath )
parseLocalPackage str =
    case String.indexes "=" str of
        eqIndex :: _ ->
            let
                path : FilePath
                path =
                    String.dropLeft (eqIndex + 1) str
            in
            if String.isEmpty path then
                Nothing

            else
                parseKernelPackage (String.left eqIndex str)
                    |> Maybe.map (\pkg -> ( pkg, path ))

        [] ->
            Nothing


{-| Tells whether `path` has the extension `ext` with something before it.
-}
hasExt : String -> String -> Bool
hasExt ext path =
    Utils.fpTakeExtension path == ext && String.length path > String.length ext


{-| Tells whether `name` is one of the names for a null device.
-}
isDevNull : String -> Bool
isDevNull name =
    name == "/dev/null" || name == "NUL" || name == "<|null"
