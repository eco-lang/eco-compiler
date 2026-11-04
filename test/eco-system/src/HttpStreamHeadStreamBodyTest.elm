module HttpStreamHeadStreamBodyTest exposing (main)

{-| HTTPS-09 (plans/kernel-lib-bug-fixes.md, decision D23): a `HEAD` request
sends no body, even if one is given, so a `streamBody` on a `HEAD` is accepted
and discarded at once: closing its source answers immediately and succeeds.

The program uploads the readable of an identity transformation as the
`streamBody` of a `HEAD` to `/slow?ms=1500` while another process writes "x"
into the transformation and closes it. The writer reports its close result
and when it finished (ms since the start) through a second identity
transformation used as a log; the main process notes when the response came.

Before the fix, native sent the HEAD with CURLOPT_NOBODY but still with the
stream body's `Transfer-Encoding: chunked` header (S/HttpStream/HttpTransfer.cpp
`buildHeaderList`), and never drained the upload channel (its close was
answered only when the transfer ended, with ECANCELED). The server waited for
a chunked body that never came, so the request ended in `Timeout` after 10 s.
Now neither twin sends the header or the body on a HEAD, and the upload side
acknowledges and drops the stream's values at once (`upDiscard`,
HttpStream.js `__headDiscard`).

-}

-- CHECK: close: ok
-- CHECK: response: GoodStatus 200
-- CHECK: order: close first
-- EXIT: 0

import Bytes exposing (Bytes)
import Http
import Http.Method
import Http.Stream
import HttpStreamTestHelp as H
import Process
import Stream
import Stream.Transformation
import Task exposing (Task)


main =
    H.program
        (\server _ ->
            H.now
                |> Task.andThen
                    (\start ->
                        Stream.Transformation.identity
                            |> Task.andThen
                                (\t ->
                                    Stream.Transformation.identity
                                        |> Task.andThen
                                            (\logT ->
                                                let
                                                    w =
                                                        Stream.Transformation.writable t

                                                    writer =
                                                        Stream.writeString "x" w
                                                            |> Task.andThen (\_ -> Stream.closeWritable w)
                                                            |> Task.map (\_ -> "ok")
                                                            |> Task.onError (\e -> Task.succeed ("err " ++ Stream.errorToString e))
                                                            |> Task.andThen
                                                                (\res ->
                                                                    H.elapsedSince start
                                                                        |> Task.andThen
                                                                            (\ms ->
                                                                                Stream.write ( res, ms ) (Stream.Transformation.writable logT)
                                                                                    |> Task.map (\_ -> ())
                                                                                    |> Task.onError (\_ -> Task.succeed ())
                                                                            )
                                                                )
                                                in
                                                Process.spawn writer
                                                    |> Task.andThen
                                                        (\_ ->
                                                            Http.Stream.task
                                                                { method = Http.Method.HEAD
                                                                , headers = []
                                                                , url = H.url server "/slow?ms=1500"
                                                                , body = Http.Stream.streamBody "text/plain" (Stream.Transformation.readable t)
                                                                , resolver =
                                                                    Http.Stream.streamResolver
                                                                        (\r ->
                                                                            case r of
                                                                                Http.GoodStatus_ m _ ->
                                                                                    Ok ("GoodStatus " ++ String.fromInt m.statusCode)

                                                                                Http.BadStatus_ m _ ->
                                                                                    Ok ("BadStatus " ++ String.fromInt m.statusCode)

                                                                                Http.NetworkError_ ->
                                                                                    Err "NetworkError"

                                                                                Http.Timeout_ ->
                                                                                    Err "Timeout"

                                                                                Http.BadUrl_ u ->
                                                                                    Err ("BadUrl " ++ u)
                                                                        )
                                                                , timeout = Just 10000
                                                                }
                                                                |> Task.onError Task.succeed
                                                        )
                                                    |> Task.andThen
                                                        (\response ->
                                                            H.elapsedSince start
                                                                |> Task.andThen
                                                                    (\respMs ->
                                                                        H.streamErr (Stream.read (Stream.Transformation.readable logT))
                                                                            |> Task.map
                                                                                (\( closeRes, closeMs ) ->
                                                                                    [ "close: " ++ closeRes
                                                                                    , "response: " ++ response
                                                                                    , "order: "
                                                                                        ++ (if closeMs < respMs then
                                                                                                "close first"

                                                                                            else
                                                                                                "response first"
                                                                                           )
                                                                                        ++ " (close at "
                                                                                        ++ String.fromInt closeMs
                                                                                        ++ " ms, response at "
                                                                                        ++ String.fromInt respMs
                                                                                        ++ " ms)"
                                                                                    ]
                                                                                )
                                                                    )
                                                        )
                                            )
                                )
                    )
        )
