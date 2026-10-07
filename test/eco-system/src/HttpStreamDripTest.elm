module HttpStreamDripTest exposing (main)

{-| A chunked body that drips over ~800 ms (`/drip-chunked`, plans/eco-system-library.md
Phase 8 step 8.3): the task resolves at the headers, the first chunk is read
long before the response completes, and the rest keeps arriving afterwards.
The order of events is logged.
-}

-- CHECK: headers
-- CHECK: first chunk
-- CHECK: closed
-- CHECK: first chunk well before the end: True
-- CHECK: total: 4096
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
                , url = H.url "/drip-chunked?bytes=4096&ms=800"
                , body = Http.Stream.emptyBody
                , resolver =
                    Http.Stream.streamResolver
                        (\r ->
                            case r of
                                Http.GoodStatus_ _ body ->
                                    Ok body

                                _ ->
                                    Err "unexpected response"
                        )
                , timeout = Nothing
                }
                |> Task.andThen
                    (\body ->
                        H.streamErr (Stream.read body)
                            |> Task.andThen
                                (\first ->
                                    H.now
                                        |> Task.andThen
                                            (\tFirst ->
                                                H.streamErr (H.readChunks body)
                                                    |> Task.andThen
                                                        (\( _, rest, _ ) ->
                                                            H.elapsedSince tFirst
                                                                |> Task.map
                                                                    (\dt ->
                                                                        [ "headers"
                                                                        , "first chunk"
                                                                        , "closed"
                                                                        , "first chunk well before the end: "
                                                                            ++ (if dt >= 300 then "True" else "False (" ++ String.fromInt dt ++ " ms)")
                                                                        , "total: " ++ String.fromInt (Bytes.width first + rest)
                                                                        ]
                                                                    )
                                                        )
                                            )
                                )
                    )
        )
