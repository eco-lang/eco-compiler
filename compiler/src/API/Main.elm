module API.Main exposing (main)

{-| The program that runs one compiler command described in JSON and answers in
JSON, so that another program can drive the compiler without a command line.

A run is one request and one response. The request is the first raw argument the
runtime gives the program, and it must be a JSON object whose `command` field
names the command: `make` (with `path`, `debug`, `optimize` and `sourcemaps`),
`format` (with `content`), `install` or `uninstall` (with `pkg`, a package name
such as `elm/json`), or `diagnostics` (with `content` or `path`). Ordinary
command-line arguments do not decode. An empty argument list, or a first
argument that does not decode, including one naming an unknown command, is not
reported: it is run as a `make` of the empty path.

_Diagnostics_ checks one module and reports its problems. Given `content`, it
only parses that text as an application module. Given `path` (and no
`content`), it runs a full `make` of that file without debug, optimisation or
source maps.

Each JSON response this module writes goes to stdout and is followed by an exit
with success, whatever it says. The exceptions: `install` and `uninstall` print
plain text such as "Success!" before their `null`, and their failures exit with
failure and no JSON; `make`, and `diagnostics` given `path`, crash when the
file at `path` does not define `main`. The responses:

  - `make` and `format` answer `{"output": ...}`, or `{"error": ...}` holding a
    string. For `make` that string is itself a JSON-encoded error report.
  - `install` and `uninstall` answer `null`, or `{"error": "Invalid package..."}`
    when `pkg` does not parse as a package name. Their other failures are not
    answered here: `API.Install` and `API.Uninstall` handle them.
  - `diagnostics` answers `{}` when there is no problem. A parse error of
    `content` gives `{"errors": [report]}`; a failed `make` of `path` gives the
    report object itself.


# Program

@docs main

-}

import API.Format as Format
import API.Install as Install
import API.Make as Make
import API.Uninstall as Uninstall
import Builder.Reporting.Exit as Exit
import Compiler.Elm.Package as Pkg
import Compiler.Json.Encode as E
import Compiler.Parse.Module as M
import Compiler.Parse.Primitives as P
import Compiler.Reporting.Error as Error
import Compiler.Reporting.Error.Syntax as E
import Compiler.Reporting.Render.Code as Code
import Eco.Console
import Eco.Env
import Eco.Process
import Json.Decode as Decode
import Json.Encode as Encode
import System.IO as IO
import Task exposing (Task)


{-| The program: it runs `app` once.
-}
main : IO.Program
main =
    IO.run app


{-| The task that reads the request, runs the command it names, and writes the
response and exits, in the shapes the module docstring lists.
-}
app : Task Never ()
app =
    getArgs
        |> Task.andThen
            (\args ->
                case args of
                    MakeArgs path debug optimize withSourceMaps ->
                        Make.run path (Make.Flags debug optimize withSourceMaps)
                            |> Task.andThen
                                (\result ->
                                    case result of
                                        Ok output ->
                                            exitWithResponse (Encode.object [ ( "output", Encode.string output ) ])

                                        Err error ->
                                            exitWithResponse (Encode.object [ ( "error", Encode.string (E.encodeUgly (Exit.toJson (Exit.makeToReport error))) ) ])
                                )

                    FormatArgs content ->
                        case Format.run content of
                            Ok output ->
                                exitWithResponse (Encode.object [ ( "output", Encode.string output ) ])

                            Err error ->
                                exitWithResponse (Encode.object [ ( "error", Encode.string error ) ])

                    InstallArgs pkgString ->
                        case P.fromByteString Pkg.parser Tuple.pair pkgString of
                            Ok pkg ->
                                Install.run pkg
                                    |> Task.andThen (\_ -> exitWithResponse Encode.null)

                            Err _ ->
                                exitWithResponse (Encode.object [ ( "error", Encode.string "Invalid package..." ) ])

                    UninstallArgs pkgString ->
                        case P.fromByteString Pkg.parser Tuple.pair pkgString of
                            Ok pkg ->
                                Uninstall.run pkg
                                    |> Task.andThen (\_ -> exitWithResponse Encode.null)

                            Err _ ->
                                exitWithResponse (Encode.object [ ( "error", Encode.string "Invalid package..." ) ])

                    DiagnosticsArgs (DiagnosticsSourceContent src) ->
                        case P.fromByteString (M.chompModule M.Application) E.ModuleBadEnd src of
                            Ok _ ->
                                exitWithResponse (Encode.object [])

                            Err err ->
                                let
                                    source : Code.Source
                                    source =
                                        Code.toSource src

                                    error : Encode.Value
                                    error =
                                        E.encodeUgly (Error.reportToJson (E.toReport source (E.ParseError err)))
                                            |> Decode.decodeString Decode.value
                                            |> Result.withDefault Encode.null
                                in
                                exitWithResponse (Encode.object [ ( "errors", Encode.list identity [ error ] ) ])

                    DiagnosticsArgs (DiagnosticsSourcePath path) ->
                        Make.run path (Make.Flags False False False)
                            |> Task.andThen
                                (\result ->
                                    case result of
                                        Ok _ ->
                                            exitWithResponse (Encode.object [])

                                        Err error ->
                                            exitWithResponse
                                                (E.encodeUgly (Exit.toJson (Exit.makeToReport error))
                                                    |> Decode.decodeString Decode.value
                                                    |> Result.withDefault Encode.null
                                                )
                                )
            )


{-| Reads the request from the first raw argument.

An empty argument list, or a first argument that `argsDecoder` rejects, gives
`MakeArgs "" False False False`, a `make` of the empty path, so a bad request is
never reported as one.

-}
getArgs : Task Never Args
getArgs =
    Eco.Env.rawArgs
        |> Task.map
            (\rawArgsList ->
                case rawArgsList of
                    jsonArg :: _ ->
                        case Decode.decodeString argsDecoder jsonArg of
                            Ok args ->
                                args

                            Err _ ->
                                MakeArgs "" False False False

                    [] ->
                        MakeArgs "" False False False
            )


{-| Writes `value` to stdout as compact JSON and exits the process with success.

A failure to write is ignored, so the process exits with success even when the
response was not written.

-}
exitWithResponse : Encode.Value -> Task Never ()
exitWithResponse value =
    Eco.Console.write Eco.Console.stdout (Encode.encode 0 value)
        |> Task.onError (\_ -> Task.succeed ())
        |> Task.andThen (\_ -> Eco.Process.exit Eco.Process.ExitSuccess)



-- ====== ARGS ======


{-| A decoded request: the command to run and its arguments.

`MakeArgs` carries the path to build and then the `debug`, `optimize` and
`sourcemaps` flags, in that order.

`FormatArgs` carries the source text to format.

`InstallArgs` and `UninstallArgs` carry the package name as text, not yet
parsed.

`DiagnosticsArgs` carries the module to check.

-}
type Args
    = MakeArgs String Bool Bool Bool
    | FormatArgs String
    | InstallArgs String
    | UninstallArgs String
    | DiagnosticsArgs DiagnosticsSource


{-| The module a diagnostics request checks.

`DiagnosticsSourceContent` carries the source text itself, which is only
parsed. `DiagnosticsSourcePath` carries the path of a file, which is built.

-}
type DiagnosticsSource
    = DiagnosticsSourceContent String
    | DiagnosticsSourcePath String


{-| A decoder for a request, choosing its fields by the `command` field.

It fails on an unknown command. A `diagnostics` request with both `content` and
`path` is read as `content`.

-}
argsDecoder : Decode.Decoder Args
argsDecoder =
    Decode.field "command" Decode.string
        |> Decode.andThen
            (\command ->
                case command of
                    "make" ->
                        Decode.map4 MakeArgs
                            (Decode.field "path" Decode.string)
                            (Decode.field "debug" Decode.bool)
                            (Decode.field "optimize" Decode.bool)
                            (Decode.field "sourcemaps" Decode.bool)

                    "format" ->
                        Decode.map FormatArgs
                            (Decode.field "content" Decode.string)

                    "install" ->
                        Decode.map InstallArgs
                            (Decode.field "pkg" Decode.string)

                    "uninstall" ->
                        Decode.map UninstallArgs
                            (Decode.field "pkg" Decode.string)

                    "diagnostics" ->
                        Decode.map DiagnosticsArgs
                            (Decode.oneOf
                                [ Decode.map DiagnosticsSourceContent (Decode.field "content" Decode.string)
                                , Decode.map DiagnosticsSourcePath (Decode.field "path" Decode.string)
                                ]
                            )

                    _ ->
                        Decode.fail ("Unknown command: " ++ command)
            )
