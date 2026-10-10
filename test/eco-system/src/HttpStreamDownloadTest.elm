module HttpStreamDownloadTest exposing (main)

{-| `Http.Stream.request` with `expectStream` downloads 1 MiB from `/bytes/1048576`
(plans/eco-system-library.md Phase 8 step 8.3): the body is read chunk by chunk
and counted, every chunk is at most 64 KiB (the transfer's channel bound), and
the first bytes are the server's pattern (i & 0xff).
-}

-- CHECK: status: 200
-- CHECK: first bytes: 0 1 2 3
-- CHECK: bytes: 1048576
-- CHECK: several chunks: True
-- CHECK: chunks <= 64 KiB: True
-- EXIT: 0

import Bytes exposing (Bytes)
import Bytes.Decode as D
import Http
import Http.Stream
import HttpStreamTestHelp as H
import Stream
import Stream.Log
import System
import Task exposing (Task)
import TestServerConfig


type Msg
    = GotStream (Result Http.Error ( Http.Metadata, Stream.Readable Bytes ))
    | GotServer TestServerConfig.Server
    | Done String
    | Logged


firstBytes : Bytes -> String
firstBytes b =
    D.decode (D.map4 (\a c d e -> List.map String.fromInt [ a, c, d, e ] |> String.join " ") D.unsignedInt8 D.unsignedInt8 D.unsignedInt8 D.unsignedInt8) b
        |> Maybe.withDefault "?"


readAll : Stream.Readable Bytes -> Task Stream.Error String
readAll stream =
    Stream.read stream
        |> Task.andThen
            (\first ->
                H.readChunks stream
                    |> Task.map
                        (\( n, total, largest ) ->
                            String.join "\n"
                                [ "first bytes: " ++ firstBytes first
                                , "bytes: " ++ String.fromInt (total + Bytes.width first)
                                , "several chunks: " ++ (if n + 1 > 1 then "True" else "False")
                                , "chunks <= 64 KiB: " ++ (if max largest (Bytes.width first) <= 65536 then "True" else "False")
                                ]
                        )
            )


main : System.Program System.Environment Msg
main =
    System.defineProgram
        { init =
            \env ->
                ( env
                , Task.perform GotServer TestServerConfig.server
                )
        , update =
            \msg env ->
                case msg of
                    GotServer server ->
                        ( env
                        , Http.Stream.request
                            { method = "GET"
                            , headers = []
                            , url = H.url server "/bytes/1048576"
                            , body = Http.Stream.emptyBody
                            , expect = Http.Stream.expectStream GotStream
                            , timeout = Nothing
                            }
                        )

                    GotStream (Ok ( meta, stream )) ->
                        ( env
                        , Stream.Log.line env.stdout ("status: " ++ String.fromInt meta.statusCode)
                            |> Task.andThen (\_ -> readAll stream)
                            |> Task.onError (\e -> Task.succeed ("read error: " ++ Stream.errorToString e))
                            |> Task.perform Done
                        )

                    GotStream (Err e) ->
                        ( env, Task.perform Done (Task.succeed ("http error: " ++ H.describeHttpError e)) )

                    Done text ->
                        ( env, Task.perform (\_ -> Logged) (Stream.Log.line env.stdout text) )

                    Logged ->
                        ( env, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
