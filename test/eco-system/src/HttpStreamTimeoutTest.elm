module HttpStreamTimeoutTest exposing (main)

{-| The timeout covers only the wait for the response headers
(plans/eco-system-library.md Phase 8 step 8.3, E.6): `/slow` (headers after
3 s) with a 300 ms timeout gives `Timeout`, promptly; `/drip` (headers at once,
body over ~1 s) with the same timeout is read to the end.
-}

-- CHECK: slow: Timeout
-- CHECK: prompt: True
-- CHECK: drip: 1024 bytes
-- EXIT: 0

import Bytes exposing (Bytes)
import Http
import Http.Stream
import HttpStreamTestHelp as H
import Stream
import Task exposing (Task)
import TestServerConfig


get : TestServerConfig.Server -> String -> Task x (Result String (Stream.Readable Bytes))
get server path =
    Http.Stream.task
        { method = "GET"
        , headers = []
        , url = H.url server path
        , body = Http.Stream.emptyBody
        , resolver =
            Http.Stream.streamResolver
                (\r ->
                    case r of
                        Http.GoodStatus_ _ body ->
                            Ok body

                        Http.Timeout_ ->
                            Err "Timeout"

                        _ ->
                            Err "other"
                )
        , timeout = Just 300
        }
        |> Task.map Ok
        |> Task.onError (\e -> Task.succeed (Err e))


main =
    H.program
        (\server _ ->
            H.now
                |> Task.andThen
                    (\t0 ->
                        get server "/slow?ms=3000"
                            |> Task.andThen
                                (\slow ->
                                    H.elapsedSince t0
                                        |> Task.andThen
                                            (\dt ->
                                                get server "/drip?bytes=1024&ms=1000"
                                                    |> Task.andThen
                                                        (\drip ->
                                                            (case drip of
                                                                Ok body ->
                                                                    H.streamErr (H.readChunks body) |> Task.map (\( _, n, _ ) -> String.fromInt n ++ " bytes")

                                                                Err e ->
                                                                    Task.succeed e
                                                            )
                                                                |> Task.map
                                                                    (\dripText ->
                                                                        [ "slow: "
                                                                            ++ (case slow of
                                                                                    Ok _ ->
                                                                                        "Ok"

                                                                                    Err e ->
                                                                                        e
                                                                               )
                                                                        , "prompt: " ++ (if dt < 2000 then "True" else "False (" ++ String.fromInt dt ++ " ms)")
                                                                        , "drip: " ++ dripText
                                                                        ]
                                                                    )
                                                        )
                                            )
                                )
                    )
        )
