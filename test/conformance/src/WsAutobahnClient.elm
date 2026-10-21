module WsAutobahnClient exposing (main)

{-| The client side of an Autobahn|Testsuite run: drives `wstest -m fuzzingserver`, which tests
the WebSocket client (see `test/conformance/autobahn.sh`; local only).

    eco make src/WsAutobahnClient.elm --output=ws-autobahn-client
    ./ws-autobahn-client ws://127.0.0.1:9001 eco

    ws-autobahn-client [BASE_URL] [AGENT] [--no-compression]

The base URL defaults to `ws://127.0.0.1:9001`, the agent name (under which the test suite files the
results) to `eco`. The client asks the test suite for the number of cases (`/getCaseCount`), runs
each case (`/runCase?case=N&agent=AGENT`) by echoing every message the test suite sends until the
connection ends, then asks it to write its reports (`/updateReports?agent=AGENT`). Cases run one
after the other, with messages up to 64 MiB, no heartbeat, and the default compression offer
(permessage-deflate without context takeover) unless `--no-compression` is given.

-}

import Bytes exposing (Bytes)
import Socket
import Stream
import System
import Task exposing (Task)
import WebSocket


type alias Options =
    { base : String
    , agent : String
    , compression : Bool
    }


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram
        (\env ->
            let
                options =
                    parseArgs (List.drop 1 env.args) { base = "", agent = "", compression = True }
                        |> (\o ->
                                { o
                                    | base = nonEmpty "ws://127.0.0.1:9001" o.base
                                    , agent = nonEmpty "eco" o.agent
                                }
                           )
            in
            run env.stdout options
                |> Task.onError
                    (\problem ->
                        Stream.logLine ("ws-autobahn-client: " ++ problem) env.stderr
                            |> Task.andThen (\_ -> System.setExitCode 1)
                    )
        )


parseArgs : List String -> Options -> Options
parseArgs args options =
    case args of
        [] ->
            options

        "--no-compression" :: rest ->
            parseArgs rest { options | compression = False }

        arg :: rest ->
            if options.base == "" then
                parseArgs rest { options | base = arg }

            else
                parseArgs rest { options | agent = arg }


nonEmpty : String -> String -> String
nonEmpty default value =
    if value == "" then
        default

    else
        value


run : Stream.Writable Bytes -> Options -> Task String ()
run stdout options =
    caseCount options
        |> Task.andThen
            (\count ->
                Stream.logLine ("ws-autobahn-client: " ++ String.fromInt count ++ " cases") stdout
                    |> Task.andThen (\_ -> runCases stdout options 1 count)
            )
        |> Task.andThen
            (\_ ->
                connect options ("/updateReports?agent=" ++ options.agent)
                    |> Task.andThen WebSocket.awaitClose
                    |> Task.mapError WebSocket.errorToString
            )
        |> Task.andThen (\_ -> Stream.logLine "ws-autobahn-client: reports updated" stdout)


connect : Options -> String -> Task WebSocket.Error (WebSocket.WebSocket WebSocket.Whole)
connect options path =
    let
        d =
            WebSocket.defaultConnectOptions (options.base ++ path)
    in
    WebSocket.connect
        { d
            | maxMessageSize = 64 * 1024 * 1024
            , heartbeat = Nothing
            , timeout = Just 60000
            , compression =
                if options.compression then
                    d.compression

                else
                    Nothing
        }


caseCount : Options -> Task String Int
caseCount options =
    connect options "/getCaseCount"
        |> Task.mapError WebSocket.errorToString
        |> Task.andThen
            (\ws ->
                Stream.read (WebSocket.readable ws)
                    |> Task.mapError Stream.errorToString
                    |> Task.andThen
                        (\message ->
                            case message of
                                WebSocket.Text text ->
                                    case String.toInt (String.trim text) of
                                        Just n ->
                                            Task.succeed n

                                        Nothing ->
                                            Task.fail ("unexpected case count " ++ text)

                                WebSocket.Binary _ ->
                                    Task.fail "unexpected binary case count"
                        )
                    |> Task.andThen (\n -> WebSocket.awaitClose ws |> Task.map (\_ -> n))
            )


runCases : Stream.Writable Bytes -> Options -> Int -> Int -> Task String ()
runCases stdout options n count =
    if n > count then
        Task.succeed ()

    else
        connect options ("/runCase?case=" ++ String.fromInt n ++ "&agent=" ++ options.agent)
            |> Task.andThen (\ws -> echo ws |> Task.andThen (\_ -> WebSocket.awaitClose ws))
            |> Task.map (\_ -> ())
            -- A case may fail the handshake on purpose; the test suite records the outcome.
            |> Task.onError (\_ -> Task.succeed ())
            |> Task.andThen
                (\_ ->
                    if modBy 50 n == 0 || n == count then
                        Stream.logLine ("ws-autobahn-client: " ++ String.fromInt n ++ " / " ++ String.fromInt count) stdout

                    else
                        Task.succeed ()
                )
            |> Task.andThen (\_ -> runCases stdout options (n + 1) count)


{-| Echo every message until the readable ends.
-}
echo : WebSocket.WebSocket WebSocket.Whole -> Task x ()
echo ws =
    Stream.read (WebSocket.readable ws)
        |> Task.andThen (\message -> Stream.write message (WebSocket.writable ws))
        |> Task.map (\_ -> True)
        |> Task.onError (\_ -> Task.succeed False)
        |> Task.andThen
            (\more ->
                if more then
                    echo ws

                else
                    Task.succeed ()
            )
