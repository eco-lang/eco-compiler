module HttpStreamTestHelp exposing (bytesOf, countChunks, describeHttpError, elapsedSince, now, program, readAllString, readChunks, streamErr, url)

{-| Shared helpers for the Http.Stream tests (not a test: no `main`).

The tests talk to the test runner's HTTP test server, whose URLs come from the
environment (`TestServerConfig.server`), and print their observations to the
program's real stdout through `Stream.Log`, so the `-- CHECK:` patterns are
matched against raw fd output.

-}

import Bytes exposing (Bytes)
import Bytes.Encode
import Http
import Stream
import Stream.Log
import System
import Task exposing (Task)
import TestServerConfig
import Time


{-| A simple program that runs `run server env` and prints every line it
returns, or `error: <reason>` if it fails.
-}
program : (TestServerConfig.Server -> System.Environment -> Task String (List String)) -> System.SimpleProgram ()
program run =
    System.defineSimpleProgram
        (\env ->
            System.endSimpleProgram
                (TestServerConfig.server
                    |> Task.andThen (\server -> run server env)
                    |> Task.map (String.join "\n")
                    |> Task.onError (\err -> Task.succeed ("error: " ++ err))
                    |> Task.andThen (Stream.Log.line env.stdout)
                )
        )


url : TestServerConfig.Server -> String -> String
url server path =
    server.baseUrl ++ path


describeHttpError : Http.Error -> String
describeHttpError err =
    case err of
        Http.BadUrl u ->
            "BadUrl " ++ u

        Http.Timeout ->
            "Timeout"

        Http.NetworkError ->
            "NetworkError"

        Http.BadStatus code ->
            "BadStatus " ++ String.fromInt code

        Http.BadBody b ->
            "BadBody " ++ b


streamErr : Task Stream.Error a -> Task String a
streamErr =
    Task.mapError Stream.errorToString


bytesOf : String -> Bytes
bytesOf s =
    Bytes.Encode.encode (Bytes.Encode.string s)


{-| Read the whole stream as UTF-8 text (chunk by chunk; the test bodies are
ASCII, so no character is split across chunks).
-}
readAllString : Stream.Readable Bytes -> Task Stream.Error String
readAllString stream =
    Stream.readBytesAsString stream
        |> Task.andThen (\s -> readAllString stream |> Task.map (\rest -> s ++ rest))
        |> Task.onError
            (\err ->
                case err of
                    Stream.Closed ->
                        Task.succeed ""

                    _ ->
                        Task.fail err
            )


{-| Read every chunk until the stream closes: ( chunks, total bytes, largest chunk ).
-}
readChunks : Stream.Readable Bytes -> Task Stream.Error ( Int, Int, Int )
readChunks stream =
    Stream.readUntilClosed
        (\b ( n, total, largest ) -> Ok ( n + 1, total + Bytes.width b, max largest (Bytes.width b) ))
        ( 0, 0, 0 )
        stream


countChunks : Stream.Readable Bytes -> Task Stream.Error Int
countChunks stream =
    readChunks stream |> Task.map (\( n, _, _ ) -> n)


now : Task x Int
now =
    Time.now |> Task.map Time.posixToMillis


elapsedSince : Int -> Task x Int
elapsedSince start =
    now |> Task.map (\t -> t - start)
