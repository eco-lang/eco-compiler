module SystemEnvironmentWorkerTest exposing (main)

{-| A `Platform.worker` whose flags are `()` reaches the program's environment through
`System.environment`, and can use `FileSystem`, `Stream` on the standard streams, `Terminal` and
`Http.Stream.task` (plans/compiler-io-on-eco-system.md P1.1, P1.4): the eco compiler is such a
program.
-}

-- CHECK: args >= 1: True
-- CHECK: read own program: True
-- CHECK: stdout is a terminal: False
-- CHECK: http status: 200
-- CHECK: stderr line
-- EXIT: 0

import Bytes
import Dict
import FileSystem
import Http
import Http.Method
import Http.Stream
import HttpStreamTestHelp as H
import Stream
import System
import Task exposing (Task)
import Terminal
import TestServerConfig


boolString : Bool -> String
boolString b =
    if b then
        "True"

    else
        "False"


httpStatus : Task x String
httpStatus =
    TestServerConfig.server
        |> Task.andThen
            (\server ->
                Http.Stream.task
                    { method = Http.Method.GET
                    , headers = []
                    , url = H.url server "/bytes/16"
                    , body = Http.Stream.emptyBody
                    , resolver =
                        Http.Stream.streamResolver
                            (\response ->
                                case response of
                                    Http.GoodStatus_ meta _ ->
                                        Ok (String.fromInt meta.statusCode)

                                    Http.BadStatus_ meta _ ->
                                        Ok (String.fromInt meta.statusCode)

                                    _ ->
                                        Ok "failed"
                            )
                    , timeout = Nothing
                    }
            )


run : Task Never ()
run =
    System.environment
        |> Task.andThen
            (\env ->
                FileSystem.readFile env.applicationPath
                    |> Task.map (\bytes -> Bytes.width bytes > 0)
                    |> Task.onError (\_ -> Task.succeed False)
                    |> Task.andThen
                        (\readOwn ->
                            Terminal.isTerminal Terminal.Stdout
                                |> Task.andThen
                                    (\tty ->
                                        httpStatus
                                            |> Task.andThen
                                                (\status ->
                                                    Stream.logLine
                                                        (String.join "\n"
                                                            [ "args >= 1: " ++ boolString (List.length env.args >= 1)
                                                            , "read own program: " ++ boolString readOwn
                                                            , "stdout is a terminal: " ++ boolString tty
                                                            , "http status: " ++ status
                                                            ]
                                                        )
                                                        env.stdout
                                                )
                                    )
                        )
                    |> Task.andThen (\_ -> Stream.logLine "stderr line" env.stderr)
            )


main : Platform.Program () () ()
main =
    Platform.worker
        { init = \() -> ( (), Task.perform (\_ -> ()) run )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
