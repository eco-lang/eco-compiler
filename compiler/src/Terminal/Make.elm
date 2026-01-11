module Terminal.Make exposing
    ( run
    , Flags(..), FlagsData, Output(..), ReportType(..)
    , output, reportType, docsFile
    , parseOutput, parseReportType, parseDocsFile
    )

{-| Build command implementation for compiling Guida and Elm code.

This module handles the `make` command which compiles source files into JavaScript,
HTML, MLIR, or validates code without output. It supports debug mode, optimization,
source maps, and documentation generation.


# Command Entry

@docs run


# Configuration Types

@docs Flags, FlagsData, Output, ReportType


# Parser Definitions

@docs output, reportType, docsFile


# Parser Functions

@docs parseOutput, parseReportType, parseDocsFile

-}

import Builder.BackgroundWriter as BW
import Builder.Build as Build
import Builder.Elm.Details as Details
import Builder.File as File
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
import Task exposing (Task)
import Terminal.Terminal.Internal exposing (Parser(..))
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Main as Utils exposing (FilePath)
import Utils.Task.Extra as Task



-- ====== FLAGS ======


{-| Configuration data for the make command, containing all flags and options.
-}
type alias FlagsData =
    { debug : Bool
    , optimize : Bool
    , withSourceMaps : Bool
    , output : Maybe Output
    , report : Maybe ReportType
    , docs : Maybe String
    , showPackageErrors : Bool
    }


{-| Wrapper type for make command flags.
-}
type Flags
    = Flags FlagsData


{-| Output format and destination for the compiled code.
-}
type Output
    = JS String
    | Html String
    | MLIR String
    | DevNull


{-| Report format type for compiler diagnostics.
-}
type ReportType
    = Json



-- ====== RUN ======


{-| Execute the make command with the given source file paths and flags.
-}
run : List String -> Flags -> Task Never ()
run paths ((Flags flagsData) as flags) =
    getStyle flagsData.report
        |> Task.andThen (runWithStyle paths flags)


runWithStyle : List String -> Flags -> Reporting.Style -> Task Never ()
runWithStyle paths flags style =
    Stuff.findRoot
        |> Task.andThen (runWithRoot paths flags style)


runWithRoot : List String -> Flags -> Reporting.Style -> Maybe FilePath -> Task Never ()
runWithRoot paths flags style maybeRoot =
    Reporting.attemptWithStyle style Exit.makeToReport <|
        case maybeRoot of
            Just root ->
                runHelp root paths style flags

            Nothing ->
                Task.succeed (Err Exit.MakeNoOutline)


type DesiredMode
    = Debug
    | Dev
    | Prod


type alias BuildContext =
    { root : FilePath
    , style : Reporting.Style
    , withSourceMaps : Bool
    , maybeOutput : Maybe Output
    , maybeDocs : Maybe FilePath
    , desiredMode : DesiredMode
    , details : Details.Details
    }


runHelp : String -> List String -> Reporting.Style -> Flags -> Task Never (Result Exit.Make ())
runHelp root paths style (Flags flagsData) =
    BW.withScope (runHelpWithScope root paths style flagsData.debug flagsData.optimize flagsData.withSourceMaps flagsData.output flagsData.docs flagsData.showPackageErrors)


runHelpWithScope : FilePath -> List String -> Reporting.Style -> Bool -> Bool -> Bool -> Maybe Output -> Maybe FilePath -> Bool -> BW.Scope -> Task Never (Result Exit.Make ())
runHelpWithScope root paths style debug optimize withSourceMaps maybeOutput maybeDocs showPackageErrors scope =
    Stuff.withRootLock root
        (Task.run
            (getMode debug optimize
                |> Task.andThen (loadDetailsAndBuild root paths style withSourceMaps maybeOutput maybeDocs showPackageErrors scope)
            )
        )


loadDetailsAndBuild : FilePath -> List String -> Reporting.Style -> Bool -> Maybe Output -> Maybe FilePath -> Bool -> BW.Scope -> DesiredMode -> Task Exit.Make ()
loadDetailsAndBuild root paths style withSourceMaps maybeOutput maybeDocs showPackageErrors scope desiredMode =
    Task.eio Exit.MakeBadDetails (Details.load style scope root (shouldUseTypedOpt maybeOutput) showPackageErrors)
        |> Task.andThen (buildWithDetails root paths style withSourceMaps maybeOutput maybeDocs desiredMode)


buildWithDetails : FilePath -> List String -> Reporting.Style -> Bool -> Maybe Output -> Maybe FilePath -> DesiredMode -> Details.Details -> Task Exit.Make ()
buildWithDetails root paths style withSourceMaps maybeOutput maybeDocs desiredMode details =
    let
        ctx : BuildContext
        ctx =
            BuildContext root style withSourceMaps maybeOutput maybeDocs desiredMode details
    in
    case paths of
        [] ->
            getExposed details
                |> Task.andThen (buildExposed style root details maybeDocs)

        p :: ps ->
            buildPaths style root details (shouldUseTypedOpt maybeOutput) (NE.Nonempty p ps)
                |> Task.andThen (handleArtifacts ctx)


shouldUseTypedOpt : Maybe Output -> Bool
shouldUseTypedOpt maybeOutput =
    case maybeOutput of
        Just (MLIR _) ->
            True

        _ ->
            False


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


handleDefaultOutput : BuildContext -> Build.Artifacts -> Task Exit.Make ()
handleDefaultOutput ctx artifacts =
    case getMains artifacts of
        [] ->
            Task.succeed ()

        [ name ] ->
            toBuilder Generate.javascriptBackend ctx.withSourceMaps Html.leadingLines ctx.root ctx.details ctx.desiredMode artifacts
                |> Task.andThen (generateHtml ctx.style "index.html" name)

        name :: names ->
            toBuilder Generate.javascriptBackend ctx.withSourceMaps 0 ctx.root ctx.details ctx.desiredMode artifacts
                |> Task.andThen (\builder -> generate ctx.style "elm.js" builder (NE.Nonempty name names))


handleJsOutput : BuildContext -> FilePath -> Build.Artifacts -> Task Exit.Make ()
handleJsOutput ctx target artifacts =
    case getNoMains artifacts of
        [] ->
            toBuilder Generate.javascriptBackend ctx.withSourceMaps 0 ctx.root ctx.details ctx.desiredMode artifacts
                |> Task.andThen (\builder -> generate ctx.style target builder (Build.getRootNames artifacts))

        name :: names ->
            Task.throw (Exit.MakeNonMainFilesIntoJavaScript name names)


handleHtmlOutput : BuildContext -> FilePath -> Build.Artifacts -> Task Exit.Make ()
handleHtmlOutput ctx target artifacts =
    hasOneMain artifacts
        |> Task.andThen (buildAndGenerateHtml ctx target artifacts)


buildAndGenerateHtml : BuildContext -> FilePath -> Build.Artifacts -> ModuleName.Raw -> Task Exit.Make ()
buildAndGenerateHtml ctx target artifacts name =
    toBuilder Generate.javascriptBackend ctx.withSourceMaps Html.leadingLines ctx.root ctx.details ctx.desiredMode artifacts
        |> Task.andThen (generateHtml ctx.style target name)


generateHtml : Reporting.Style -> FilePath -> ModuleName.Raw -> String -> Task Exit.Make ()
generateHtml style target name builder =
    generate style target (Html.sandwich name builder) (NE.Nonempty name [])


handleMlirOutput : BuildContext -> FilePath -> Build.Artifacts -> Task Exit.Make ()
handleMlirOutput ctx target artifacts =
    case getNoMains artifacts of
        [] ->
            toMonoBuilder Generate.mlirBackend ctx.withSourceMaps 0 ctx.root ctx.details ctx.desiredMode artifacts
                |> Task.andThen (\builder -> generate ctx.style target builder (Build.getRootNames artifacts))

        name :: names ->
            Task.throw (Exit.MakeNonMainFilesIntoJavaScript name names)



-- ====== GET INFORMATION ======


getStyle : Maybe ReportType -> Task Never Reporting.Style
getStyle report =
    case report of
        Nothing ->
            Reporting.terminal

        Just Json ->
            Task.succeed Reporting.json


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


buildExposed : Reporting.Style -> FilePath -> Details.Details -> Maybe FilePath -> NE.Nonempty ModuleName.Raw -> Task Exit.Make ()
buildExposed style root details maybeDocs exposed =
    let
        docsGoal : Build.DocsGoal ()
        docsGoal =
            Maybe.unwrap Build.ignoreDocs Build.writeDocs maybeDocs
    in
    Task.eio Exit.MakeCannotBuild <|
        Build.fromExposed BD.unit
            BE.unit
            style
            root
            details
            docsGoal
            exposed


buildPaths : Reporting.Style -> FilePath -> Details.Details -> Bool -> NE.Nonempty FilePath -> Task Exit.Make Build.Artifacts
buildPaths style root details needsTypedOpt paths =
    Build.fromPaths style root details needsTypedOpt paths |> Task.eio Exit.MakeCannotBuild



-- ====== GET MAINS ======


getMains : Build.Artifacts -> List ModuleName.Raw
getMains (Build.Artifacts artifacts) =
    List.filterMap (getMain artifacts.modules) (NE.toList artifacts.roots)


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


isMain : ModuleName.Raw -> Build.Module -> Bool
isMain targetName modul =
    case modul of
        Build.Fresh name _ (Opt.LocalGraph maybeMain _ _) _ _ ->
            Maybe.isJust maybeMain && name == targetName

        Build.Cached name mainIsDefined _ ->
            mainIsDefined && name == targetName



-- ====== HAS ONE MAIN ======


hasOneMain : Build.Artifacts -> Task Exit.Make ModuleName.Raw
hasOneMain (Build.Artifacts artifacts) =
    case artifacts.roots of
        NE.Nonempty root [] ->
            Task.mio Exit.MakeNoMain (Task.succeed <| getMain artifacts.modules root)

        NE.Nonempty _ (_ :: _) ->
            Task.throw Exit.MakeMultipleFilesIntoHtml



-- ====== GET MAINLESS ======


getNoMains : Build.Artifacts -> List ModuleName.Raw
getNoMains (Build.Artifacts artifacts) =
    List.filterMap (getNoMain artifacts.modules) (NE.toList artifacts.roots)


getNoMain : List Build.Module -> Build.Root -> Maybe ModuleName.Raw
getNoMain modules root =
    case root of
        Build.Inside name ->
            if List.any (isMain name) modules then
                Nothing

            else
                Just name

        Build.Outside name _ (Opt.LocalGraph maybeMain _ _) _ _ ->
            case maybeMain of
                Just _ ->
                    Nothing

                Nothing ->
                    Just name



-- ====== GENERATE ======


generate : Reporting.Style -> FilePath -> String -> NE.Nonempty ModuleName.Raw -> Task Exit.Make ()
generate style target builder names =
    Task.io
        (Utils.dirCreateDirectoryIfMissing True (Utils.fpTakeDirectory target)
            |> Task.andThen (\_ -> File.writeUtf8 target builder)
            |> Task.andThen (\_ -> Reporting.reportGenerate style names target)
        )



-- ====== TO BUILDER ======


toBuilder : CodeGen.CodeGen -> Bool -> Int -> FilePath -> Details.Details -> DesiredMode -> Build.Artifacts -> Task Exit.Make String
toBuilder backend withSourceMaps leadingLines root details desiredMode artifacts =
    (case desiredMode of
        Debug ->
            Generate.debug backend withSourceMaps leadingLines root details artifacts

        Dev ->
            Generate.dev backend withSourceMaps leadingLines root details artifacts

        Prod ->
            Generate.prod backend withSourceMaps leadingLines root details artifacts
    )
        |> Task.map CodeGen.outputToString
        |> Task.mapError Exit.MakeBadGenerate


{-| Build using monomorphized code generation (for MLIR mono backend)
-}
toMonoBuilder : CodeGen.MonoCodeGen -> Bool -> Int -> FilePath -> Details.Details -> DesiredMode -> Build.Artifacts -> Task Exit.Make String
toMonoBuilder backend withSourceMaps leadingLines root details desiredMode artifacts =
    (case desiredMode of
        Debug ->
            Generate.monoDev backend withSourceMaps leadingLines root details artifacts

        Dev ->
            Generate.monoDev backend withSourceMaps leadingLines root details artifacts

        Prod ->
            Generate.monoDev backend withSourceMaps leadingLines root details artifacts
    )
        |> Task.map CodeGen.outputToString
        |> Task.mapError Exit.MakeBadGenerate



-- ====== PARSERS ======


{-| Parser definition for report type command-line arguments.
-}
reportType : Parser
reportType =
    Parser
        { singular = "report type"
        , plural = "report types"
        , suggest = \_ -> Task.succeed [ "json" ]
        , examples = \_ -> Task.succeed [ "json" ]
        }


{-| Parse a string into a ReportType value.
-}
parseReportType : String -> Maybe ReportType
parseReportType string =
    if string == "json" then
        Just Json

    else
        Nothing


{-| Parser definition for output file command-line arguments.
-}
output : Parser
output =
    Parser
        { singular = "output file"
        , plural = "output files"
        , suggest = \_ -> Task.succeed []
        , examples = \_ -> Task.succeed [ "elm.js", "index.html", "output.mlir", "/dev/null" ]
        }


{-| Parse a string into an Output value based on file extension.
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

    else
        Nothing


{-| Parser definition for documentation file command-line arguments.
-}
docsFile : Parser
docsFile =
    Parser
        { singular = "json file"
        , plural = "json files"
        , suggest = \_ -> Task.succeed []
        , examples = \_ -> Task.succeed [ "docs.json", "documentation.json" ]
        }


{-| Parse a string into a documentation file path (must be .json extension).
-}
parseDocsFile : String -> Maybe String
parseDocsFile name =
    if hasExt ".json" name then
        Just name

    else
        Nothing


hasExt : String -> String -> Bool
hasExt ext path =
    Utils.fpTakeExtension path == ext && String.length path > String.length ext


isDevNull : String -> Bool
isDevNull name =
    name == "/dev/null" || name == "NUL" || name == "<|null"
