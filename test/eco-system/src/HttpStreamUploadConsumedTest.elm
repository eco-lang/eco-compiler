module HttpStreamUploadConsumedTest exposing (main)

{-| HTTPS-01 (plans/kernel-lib-bug-fixes.md, decision D23: keep the design and
pin it): a `streamBody` whose readable was already consumed by an earlier
upload is a closed stream, and a closed stream is an empty body.

The program uploads `Stream.fromList [ "abc" ]` with PUT to `/anything`, which
drains the readable (the stream table then erases its pair), and uploads the
same readable a second time. The kernels treat a stream id they no longer
know as ended ("missing = ended", S/Stream/Stream.hpp `pipeStreams`,
HttpStream.js), so the second upload succeeds with an empty body. This is
the documented behaviour, the same as `Stream.read source` failing with
`Closed` after an upload (HttpStreamUploadTest); it passes today on both
backends, and a change to reject the second upload must update this test.

-}

-- CHECK: first upload: [abc]
-- CHECK: second upload: [] PUT
-- EXIT: 0

import Bytes
import Http
import Http.Method
import Http.Stream
import HttpStreamTestHelp as H
import Json.Decode as D
import Stream
import Task exposing (Task)
import TestServerConfig


upload : TestServerConfig.Server -> Stream.Readable Bytes.Bytes -> Task x String
upload server source =
    Http.Stream.task
        { method = Http.Method.PUT
        , headers = []
        , url = H.url server "/anything"
        , body = Http.Stream.streamBody "text/plain" source
        , resolver =
            Http.Stream.streamResolver
                (\r ->
                    case r of
                        Http.GoodStatus_ _ body ->
                            Ok body

                        Http.BadStatus_ m _ ->
                            Err ("BadStatus " ++ String.fromInt m.statusCode)

                        Http.NetworkError_ ->
                            Err "NetworkError"

                        Http.Timeout_ ->
                            Err "Timeout"

                        Http.BadUrl_ u ->
                            Err ("BadUrl " ++ u)
                )
        , timeout = Just 10000
        }
        |> Task.andThen (\body -> H.streamErr (H.readAllString body))
        |> Task.map
            (\json ->
                case D.decodeString (D.map2 Tuple.pair (D.field "body" D.string) (D.field "method" D.string)) json of
                    Ok ( b, m ) ->
                        "[" ++ b ++ "] " ++ m

                    Err _ ->
                        "bad echo: " ++ json
            )
        |> Task.onError Task.succeed


main =
    H.program
        (\server _ ->
            H.streamErr (Stream.fromList [ H.bytesOf "abc" ])
                |> Task.andThen
                    (\source ->
                        upload server source
                            |> Task.andThen
                                (\first ->
                                    upload server source
                                        |> Task.map (\second -> [ "first upload: " ++ first, "second upload: " ++ second ])
                                )
                    )
        )
