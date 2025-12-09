module Terminal.Make exposing
    ( Flags(..)
    , Output(..)
    , ReportType(..)
    , docsFile
    , output
    , parseDocsFile
    , parseOutput
    , parseReportType
    , reportType
    , run
    )

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



-- FLAGS


type Flags
    = Flags Bool Bool Bool (Maybe Output) (Maybe ReportType) (Maybe String)


type Output
    = JS String
    | Html String
    | MLIR String
    | DevNull


type ReportType
    = Json



-- RUN


run : List String -> Flags -> Task Never ()
run paths ((Flags _ _ _ _ report _) as flags) =
    getStyle report
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
runHelp root paths style (Flags debug optimize withSourceMaps maybeOutput _ maybeDocs) =
    BW.withScope (runHelpWithScope root paths style debug optimize withSourceMaps maybeOutput maybeDocs)


runHelpWithScope : FilePath -> List String -> Reporting.Style -> Bool -> Bool -> Bool -> Maybe Output -> Maybe FilePath -> BW.Scope -> Task Never (Result Exit.Make ())
runHelpWithScope root paths style debug optimize withSourceMaps maybeOutput maybeDocs scope =
    Stuff.withRootLock root
        (Task.run
            (getMode debug optimize
                |> Task.andThen (loadDetailsAndBuild root paths style withSourceMaps maybeOutput maybeDocs scope)
            )
        )


loadDetailsAndBuild : FilePath -> List String -> Reporting.Style -> Bool -> Maybe Output -> Maybe FilePath -> BW.Scope -> DesiredMode -> Task Exit.Make ()
loadDetailsAndBuild root paths style withSourceMaps maybeOutput maybeDocs scope desiredMode =
    Task.eio Exit.MakeBadDetails (Details.load style scope root)
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
            toMonoBuilder Generate.mlirMonoBackend ctx.withSourceMaps 0 ctx.root ctx.details ctx.desiredMode artifacts
                |> Task.andThen (\builder -> generate ctx.style target builder (Build.getRootNames artifacts))

        name :: names ->
            Task.throw (Exit.MakeNonMainFilesIntoJavaScript name names)



-- GET INFORMATION


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
getExposed (Details.Details _ validOutline _ _ _ _) =
    case validOutline of
        Details.ValidApp _ ->
            Task.throw Exit.MakeAppNeedsFileNames

        Details.ValidPkg _ exposed _ ->
            case exposed of
                [] ->
                    Task.throw Exit.MakePkgNeedsExposing

                m :: ms ->
                    Task.succeed (NE.Nonempty m ms)



-- BUILD PROJECTS


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
    Task.eio Exit.MakeCannotBuild <|
        Build.fromPaths style root details needsTypedOpt paths



-- GET MAINS


getMains : Build.Artifacts -> List ModuleName.Raw
getMains (Build.Artifacts _ _ roots modules) =
    List.filterMap (getMain modules) (NE.toList roots)


getMain : List Build.Module -> Build.Root -> Maybe ModuleName.Raw
getMain modules root =
    case root of
        Build.Inside name ->
            if List.any (isMain name) modules then
                Just name

            else
                Nothing

        Build.Outside name _ (Opt.LocalGraph maybeMain _ _) _ ->
            maybeMain
                |> Maybe.map (\_ -> name)


isMain : ModuleName.Raw -> Build.Module -> Bool
isMain targetName modul =
    case modul of
        Build.Fresh name _ (Opt.LocalGraph maybeMain _ _) _ ->
            Maybe.isJust maybeMain && name == targetName

        Build.Cached name mainIsDefined _ ->
            mainIsDefined && name == targetName



-- HAS ONE MAIN


hasOneMain : Build.Artifacts -> Task Exit.Make ModuleName.Raw
hasOneMain (Build.Artifacts _ _ roots modules) =
    case roots of
        NE.Nonempty root [] ->
            Task.mio Exit.MakeNoMain (Task.succeed <| getMain modules root)

        NE.Nonempty _ (_ :: _) ->
            Task.throw Exit.MakeMultipleFilesIntoHtml



-- GET MAINLESS


getNoMains : Build.Artifacts -> List ModuleName.Raw
getNoMains (Build.Artifacts _ _ roots modules) =
    List.filterMap (getNoMain modules) (NE.toList roots)


getNoMain : List Build.Module -> Build.Root -> Maybe ModuleName.Raw
getNoMain modules root =
    case root of
        Build.Inside name ->
            if List.any (isMain name) modules then
                Nothing

            else
                Just name

        Build.Outside name _ (Opt.LocalGraph maybeMain _ _) _ ->
            case maybeMain of
                Just _ ->
                    Nothing

                Nothing ->
                    Just name



-- GENERATE


generate : Reporting.Style -> FilePath -> String -> NE.Nonempty ModuleName.Raw -> Task Exit.Make ()
generate style target builder names =
    Task.io
        (Utils.dirCreateDirectoryIfMissing True (Utils.fpTakeDirectory target)
            |> Task.andThen (\_ -> File.writeUtf8 target builder)
            |> Task.andThen (\_ -> Reporting.reportGenerate style names target)
        )



-- TO BUILDER


toBuilder : CodeGen.CodeGen -> Bool -> Int -> FilePath -> Details.Details -> DesiredMode -> Build.Artifacts -> Task Exit.Make String
toBuilder backend withSourceMaps leadingLines root details desiredMode artifacts =
    Task.mapError Exit.MakeBadGenerate <|
        Task.map CodeGen.outputToString <|
            case desiredMode of
                Debug ->
                    Generate.debug backend withSourceMaps leadingLines root details artifacts

                Dev ->
                    Generate.dev backend withSourceMaps leadingLines root details artifacts

                Prod ->
                    Generate.prod backend withSourceMaps leadingLines root details artifacts


{-| Build using typed code generation (for MLIR backend)
-}
toTypedBuilder : CodeGen.TypedCodeGen -> Bool -> Int -> FilePath -> Details.Details -> DesiredMode -> Build.Artifacts -> Task Exit.Make String
toTypedBuilder backend withSourceMaps leadingLines root details desiredMode artifacts =
    Task.mapError Exit.MakeBadGenerate <|
        Task.map CodeGen.outputToString <|
            case desiredMode of
                Debug ->
                    -- TODO: Add typed debug when needed
                    Generate.typedDev backend withSourceMaps leadingLines root details artifacts

                Dev ->
                    Generate.typedDev backend withSourceMaps leadingLines root details artifacts

                Prod ->
                    -- TODO: Add typed prod when needed
                    Generate.typedDev backend withSourceMaps leadingLines root details artifacts


{-| Build using monomorphized code generation (for MLIR mono backend)
-}
toMonoBuilder : CodeGen.MonoCodeGen -> Bool -> Int -> FilePath -> Details.Details -> DesiredMode -> Build.Artifacts -> Task Exit.Make String
toMonoBuilder backend withSourceMaps leadingLines root details desiredMode artifacts =
    Task.mapError Exit.MakeBadGenerate <|
        Task.map CodeGen.outputToString <|
            case desiredMode of
                Debug ->
                    Generate.monoDev backend withSourceMaps leadingLines root details artifacts

                Dev ->
                    Generate.monoDev backend withSourceMaps leadingLines root details artifacts

                Prod ->
                    Generate.monoDev backend withSourceMaps leadingLines root details artifacts


-- PARSERS


reportType : Parser
reportType =
    Parser
        { singular = "report type"
        , plural = "report types"
        , suggest = \_ -> Task.succeed [ "json" ]
        , examples = \_ -> Task.succeed [ "json" ]
        }


parseReportType : String -> Maybe ReportType
parseReportType string =
    if string == "json" then
        Just Json

    else
        Nothing


output : Parser
output =
    Parser
        { singular = "output file"
        , plural = "output files"
        , suggest = \_ -> Task.succeed []
        , examples = \_ -> Task.succeed [ "elm.js", "index.html", "output.mlir", "/dev/null" ]
        }


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


docsFile : Parser
docsFile =
    Parser
        { singular = "json file"
        , plural = "json files"
        , suggest = \_ -> Task.succeed []
        , examples = \_ -> Task.succeed [ "docs.json", "documentation.json" ]
        }


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
