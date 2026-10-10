module HttpStreamUploadErrorTest exposing (main)

{-| Stream bodies that cannot be sent (plans/eco-system-library.md Phase 8 step
8.2, E.6):

  - the source stream is cancelled mid-upload (`cancelWritable` on the
    transformation feeding it): the upload pump aborts the transfer and the
    request fails with `NetworkError_`;
  - the source stream is locked by a parked read: it cannot be consumed, and
    the request fails with `NetworkError_` at once.

-}

-- CHECK: cancelled source: NetworkError
-- CHECK: locked source: NetworkError
-- EXIT: 0

import Bytes exposing (Bytes)
import Http
import Http.Stream
import HttpStreamTestHelp as H
import Process
import Stream
import System
import Task exposing (Task)
import TestServerConfig


upload : TestServerConfig.Server -> Stream.Readable Bytes -> Task x String
upload server source =
    Http.Stream.task
        { method = "POST"
        , headers = []
        , url = H.url server "/anything"
        , body = Http.Stream.streamBody "text/plain" source
        , resolver =
            Http.Stream.streamResolver
                (\r ->
                    case r of
                        Http.NetworkError_ ->
                            Err "NetworkError"

                        Http.GoodStatus_ m _ ->
                            Ok ("GoodStatus " ++ String.fromInt m.statusCode)

                        _ ->
                            Err "other"
                )
        , timeout = Just 5000
        }
        |> Task.onError Task.succeed


main : System.SimpleProgram ()
main =
    H.program
        (\server _ ->
            Stream.identityTransformation
                |> Task.andThen
                    (\t ->
                        Process.spawn
                            (Stream.write (H.bytesOf "partial") (Stream.writable t)
                                |> Task.andThen (\_ -> Process.sleep 100)
                                |> Task.andThen (\_ -> Stream.cancelWritable "boom" (Stream.writable t))
                                |> Task.onError (\_ -> Task.succeed ())
                            )
                            |> Task.andThen (\_ -> upload server (Stream.readable t))
                    )
                |> Task.andThen
                    (\cancelled ->
                        Stream.identityTransformation
                            |> Task.andThen
                                (\t ->
                                    Process.spawn (Stream.read (Stream.readable t) |> Task.onError (\_ -> Task.succeed (H.bytesOf "")))
                                        |> Task.andThen (\_ -> Process.sleep 10)
                                        |> Task.andThen (\_ -> upload server (Stream.readable t))
                                        |> Task.andThen
                                            (\locked ->
                                                -- release the parked reader so nothing is left waiting
                                                Stream.closeWritable (Stream.writable t)
                                                    |> Task.onError (\_ -> Task.succeed ())
                                                    |> Task.map (\_ -> [ "cancelled source: " ++ cancelled, "locked source: " ++ locked ])
                                            )
                                )
                    )
        )
