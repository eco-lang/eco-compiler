module API.Make exposing (run, Flags(..))

{-| Build Elm projects into JavaScript or HTML. This module handles the complete
build pipeline including dependency resolution, compilation, and code generation.

Supports debug mode for enhanced development experience, optimized production builds,
and optional source map generation.


# Build Pipeline

@docs run, Flags

-}

import Builder.BackgroundWriter as BW
import Builder.Build as Build
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
import Task exposing (Task)
import Utils.Crash exposing (crash)
import Utils.Main exposing (FilePath)
import Utils.Task.Extra as Task



-- ====== FLAGS ======


{-| Compilation flags controlling debug mode, optimization, and source map generation.
-}
type Flags
    = Flags Bool Bool Bool



-- ====== RUN ======


{-| Build an Elm project from a source file path with the specified flags.
Returns the compiled output as a string or an error describing what went wrong.
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
                                Task.eio Exit.MakeBadDetails (Details.load style scope root False False)
                                    |> Task.andThen
                                        (\details ->
                                            buildPaths style root details (NE.Nonempty path [])
                                                |> Task.andThen
                                                    (\artifacts ->
                                                        case getMains artifacts of
                                                            [] ->
                                                                -- Task.succeed ()
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


buildPaths : Reporting.Style -> FilePath -> Details.Details -> NE.Nonempty FilePath -> Task Exit.Make Build.Artifacts
buildPaths style root details paths =
    Build.fromPaths style root details False paths |> Task.eio Exit.MakeCannotBuild



-- ====== GET MAINS ======


getMains : Build.Artifacts -> List ModuleName.Raw
getMains (Build.Artifacts artifactsData) =
    List.filterMap (getMain artifactsData.modules) (NE.toList artifactsData.roots)


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



-- ====== TO BUILDER ======


type DesiredMode
    = Debug
    | Dev
    | Prod


toBuilder : Bool -> Int -> FilePath -> Details.Details -> DesiredMode -> Build.Artifacts -> Task Exit.Make String
toBuilder withSourceMaps leadingLines root details desiredMode artifacts =
    (case desiredMode of
        Debug ->
            Generate.debug Generate.javascriptBackend withSourceMaps leadingLines root details artifacts

        Dev ->
            Generate.dev Generate.javascriptBackend withSourceMaps leadingLines root details artifacts

        Prod ->
            Generate.prod Generate.javascriptBackend withSourceMaps leadingLines root details artifacts
    )
        |> Task.map CodeGen.outputToString
        |> Task.mapError Exit.MakeBadGenerate



-- ====== PARSERS ======
