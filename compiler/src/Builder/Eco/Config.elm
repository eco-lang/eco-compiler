module Builder.Eco.Config exposing (load)

{-| Read the project's `eco-config.json` (tunable compiler settings) from disk.

The pure data, decoder, and defaults live in `Compiler.Eco.Config`; this module
only adds the IO: locate the file, read it, decode it, clamp out-of-range
values (emitting warnings), and surface errors as `Exit.Make`.

@docs load

-}

import Builder.File as File
import Builder.Reporting.Exit as Exit
import Compiler.Eco.Config as Config exposing (EcoConfig)
import Compiler.Json.Decode as D
import System.IO as IO exposing (FilePath)
import Task exposing (Task)
import Utils.Main as Utils
import Utils.Task.Extra as Task


{-| Load the effective config.

  - `maybeExplicit` is the `--config <path>` override, if any.
  - Otherwise the default location `<root>/eco-config.json` is used.

Rules:

  - Default location absent → `Config.default` (silent; the common case).
  - Explicit path absent → hard error (`Exit.MakeConfigNotFound`).
  - Present but malformed → hard error (`Exit.MakeBadConfig`).
  - Out-of-range values are clamped, with a warning printed to stderr.

-}
load : Maybe FilePath -> FilePath -> Task Exit.Make EcoConfig
load maybeExplicit root =
    let
        path : FilePath
        path =
            Maybe.withDefault (root ++ "/eco-config.json") maybeExplicit
    in
    (Utils.dirDoesFileExist path |> Task.mapError never)
        |> Task.andThen
            (\exists ->
                if not exists then
                    case maybeExplicit of
                        Just explicitPath ->
                            Task.throw (Exit.MakeConfigNotFound explicitPath)

                        Nothing ->
                            Task.succeed Config.default

                else
                    (File.readUtf8 path |> Task.mapError never)
                        |> Task.andThen
                            (\contents ->
                                case D.fromByteString Config.decoder contents of
                                    Ok cfg ->
                                        finishWithWarnings cfg

                                    Err err ->
                                        Task.throw (Exit.MakeBadConfig path err)
                            )
            )


{-| Clamp out-of-range values and print any resulting warnings to stderr.
-}
finishWithWarnings : EcoConfig -> Task Exit.Make EcoConfig
finishWithWarnings cfg =
    let
        ( clamped, warnings ) =
            Config.clamp cfg
    in
    List.foldl
        (\msg acc -> acc |> Task.andThen (\_ -> Task.io (IO.writeLn IO.stderr msg)))
        (Task.succeed ())
        warnings
        |> Task.map (\_ -> clamped)
