module HttpStreamTruncatedTest exposing (main)

{-| A body cut short after the headers (`/truncate`: Content-Length 1000, 10
bytes, close; plans/eco-system-library.md Phase 8 step 8.3, E.6): the task
succeeds at the headers, the reader gets the 10 bytes, then `Cancelled` with
the curl error ("network error: …").
-}

-- CHECK: status: 200
-- CHECK: first: 10 bytes
-- CHECK: then: err Cancelled: network error:
-- EXIT: 0

import Bytes
import Http
import Http.Stream
import HttpStreamTestHelp as H
import Stream
import Task


main =
    H.program
        (\_ ->
            Http.Stream.task
                { method = "GET"
                , headers = []
                , url = H.url "/truncate"
                , body = Http.Stream.emptyBody
                , resolver =
                    Http.Stream.streamResolver
                        (\r ->
                            case r of
                                Http.GoodStatus_ meta body ->
                                    Ok ( meta.statusCode, body )

                                _ ->
                                    Err "unexpected response"
                        )
                , timeout = Nothing
                }
                |> Task.andThen
                    (\( status, body ) ->
                        H.streamErr (Stream.read body)
                            |> Task.andThen
                                (\first ->
                                    H.readChunks body
                                        |> Task.map (\( _, n, _ ) -> "ok " ++ String.fromInt n ++ " more bytes")
                                        |> Task.onError (\e -> Task.succeed ("err " ++ Stream.errorToString e))
                                        |> Task.map
                                            (\after ->
                                                [ "status: " ++ String.fromInt status
                                                , "first: " ++ String.fromInt (Bytes.width first) ++ " bytes"
                                                , "then: " ++ after
                                                ]
                                            )
                                )
                    )
        )
