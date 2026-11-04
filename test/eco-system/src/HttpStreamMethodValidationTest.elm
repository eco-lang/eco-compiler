module HttpStreamMethodValidationTest exposing (main)

{-| HTTPS-03 and HTTPS-NEW-2 (plans/kernel-lib-bug-fixes.md, decision D23): an
`Http.Stream` request whose method is not an RFC 9110 token is rejected
before anything is sent, on both backends.

  - HTTPS-03: `UNKNOWN ""` is not legal HTTP. With a body, native libcurl
    was given `CURLOPT_CUSTOMREQUEST ""` (S/HttpStream/HttpTransfer.cpp
    `configure`) and sent the request line ` /anything HTTP/1.1`, which the
    test server parsed as method `/anything`; without a body, native sent
    GET. The JS twin sent `method || 'GET'`, a GET in both cases.
  - HTTPS-NEW-2: the method string was not validated, so CR/LF in it
    injected a whole request (native: the server saw `GET /anything` with an
    `x-injected` header), and a space split the request line. Node rejected
    both (ERR_INVALID_HTTP_TOKEN, mapped to NetworkError).

Both twins now check the method against the RFC 9110 token rule before
anything is sent (S/HttpStream/HttpStream.cpp, with elm/http's
`HttpService::isHttpToken`; HttpStream.js `_HttpStream_isToken`) and fail with
`BadUrl`, the request error D23 names and the one elm/http gives.
`UNKNOWN "PROPFIND"` stays valid (HttpMethodOptionsTest).

-}

-- CHECK: empty method with body: BadUrl
-- CHECK: empty method no body: BadUrl
-- CHECK: injected method: BadUrl
-- CHECK: space in method: BadUrl
-- CHECK-NOT: x-injected
-- EXIT: 0

import Bytes exposing (Bytes)
import Dict
import Http
import Http.Method
import Http.Stream
import HttpStreamTestHelp as H
import Json.Decode as D
import Stream
import Task exposing (Task)
import TestServerConfig


{-| Sends `method` to `/anything` and describes the outcome: the error kind,
or `GoodStatus <echoed method>` plus ` x-injected` when the server saw an
`x-injected` header.
-}
send : TestServerConfig.Server -> String -> Http.Stream.Body -> Task x String
send server method body =
    Http.Stream.task
        { method = Http.Method.UNKNOWN method
        , headers = []
        , url = H.url server "/anything"
        , body = body
        , resolver =
            Http.Stream.streamResolver
                (\r ->
                    case r of
                        Http.GoodStatus_ _ b ->
                            Ok b

                        Http.BadStatus_ m _ ->
                            Err ("BadStatus " ++ String.fromInt m.statusCode)

                        Http.NetworkError_ ->
                            Err "NetworkError"

                        Http.Timeout_ ->
                            Err "Timeout"

                        Http.BadUrl_ _ ->
                            Err "BadUrl"
                )
        , timeout = Just 10000
        }
        |> Task.andThen (\b -> H.streamErr (H.readAllString b))
        |> Task.map
            (\json ->
                case D.decodeString (D.map2 Tuple.pair (D.field "method" D.string) (D.field "headers" (D.dict D.string))) json of
                    Ok ( m, headers ) ->
                        "GoodStatus "
                            ++ m
                            ++ (if Dict.member "x-injected" headers then
                                    " x-" ++ "injected"

                                else
                                    ""
                               )

                    Err _ ->
                        "bad echo: " ++ json
            )
        |> Task.onError Task.succeed


main =
    H.program
        (\server _ ->
            Task.sequence
                [ send server "" (Http.Stream.bytesBody "text/plain" (H.bytesOf "x"))
                    |> Task.map (\s -> "empty method with body: " ++ s)
                , send server "" Http.Stream.emptyBody
                    |> Task.map (\s -> "empty method no body: " ++ s)
                , send server "GET /anything HTTP/1.1\u{000D}\nX-Injected: 1\u{000D}\n\u{000D}\nGET" Http.Stream.emptyBody
                    |> Task.map (\s -> "injected method: " ++ s)
                , send server "PRO PFIND" Http.Stream.emptyBody
                    |> Task.map (\s -> "space in method: " ++ s)
                ]
        )
