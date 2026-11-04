module HttpStreamProxyTest exposing (main)

{-| HTTPS-NEW-1 (plans/kernel-lib-bug-fixes.md): an `Http.Stream` request to an
https URL through an HTTP proxy (`https_proxy`) reports the origin server's
response, not the proxy's answer to CONNECT.

The test server's CONNECT proxy (`ECO_TEST_PROXY_URL`, test/TestHttpServer.hpp)
tunnels to its HTTPS port. The program asks for `/status/404` on the HTTPS
server through it and prints the response kind, status text and content
type, and whether the proxy's tunnel count went up (`/proxy-connects`, on the
plain port, which `https_proxy` does not affect).

Before the fix libcurl passed the proxy's `HTTP/1.1 200 Connection
established` head to the header callback (no CURLOPT_SUPPRESS_CONNECT_HEADERS
in S/HttpStream/HttpTransfer.cpp `configure`), and the kernel posted it as the
final response: `GoodStatus 200 Connection established` with no headers.

The JS runner has neither an HTTPS server (both URLs name its plain port) nor
the CONNECT proxy (no `ECO_TEST_PROXY_URL`), so the test is native-only.

-}

-- SKIP-JS: the JS runner has no HTTPS test server and no CONNECT proxy (ECO_TEST_PROXY_URL)
-- ENV: https_proxy=${ECO_TEST_PROXY_URL}
-- ENV: HTTPS_PROXY=${ECO_TEST_PROXY_URL}
-- UNSETENV: no_proxy NO_PROXY http_proxy HTTP_PROXY all_proxy ALL_PROXY
-- CHECK: via proxy: BadStatus 404 Status
-- CHECK: content-type: text/plain
-- CHECK: tunnelled: True
-- EXIT: 0

import Bytes exposing (Bytes)
import Dict
import Http
import Http.Method
import Http.Stream
import HttpStreamTestHelp as H
import Stream
import Task exposing (Task)
import TestServerConfig


get : String -> Task x (Result String ( String, Http.Metadata, Stream.Readable Bytes ))
get url =
    Http.Stream.task
        { method = Http.Method.GET
        , headers = []
        , url = url
        , body = Http.Stream.emptyBody
        , resolver =
            Http.Stream.streamResolver
                (\r ->
                    case r of
                        Http.GoodStatus_ m b ->
                            Ok ( "GoodStatus", m, b )

                        Http.BadStatus_ m b ->
                            Ok ( "BadStatus", m, b )

                        Http.NetworkError_ ->
                            Err "NetworkError"

                        Http.Timeout_ ->
                            Err "Timeout"

                        Http.BadUrl_ u ->
                            Err ("BadUrl " ++ u)
                )
        , timeout = Just 10000
        }
        |> Task.map Ok
        |> Task.onError (\e -> Task.succeed (Err e))


{-| The proxy's tunnel count, or Nothing when the server has no such route.
-}
proxyConnects : TestServerConfig.Server -> Task x (Maybe Int)
proxyConnects server =
    get (H.url server "/proxy-connects")
        |> Task.andThen
            (\res ->
                case res of
                    Ok ( "GoodStatus", _, b ) ->
                        H.readAllString b
                            |> Task.map String.toInt
                            |> Task.onError (\_ -> Task.succeed Nothing)

                    _ ->
                        Task.succeed Nothing
            )


main =
    H.program
        (\server _ ->
            proxyConnects server
                |> Task.andThen
                    (\before ->
                        get (server.httpsBaseUrl ++ "/status/404")
                            |> Task.andThen
                                (\res ->
                                    proxyConnects server
                                        |> Task.map
                                            (\after ->
                                                let
                                                    tunnelled =
                                                        case ( before, after ) of
                                                            ( Just b, Just a ) ->
                                                                if a > b then
                                                                    "True"

                                                                else
                                                                    "False"

                                                            _ ->
                                                                "n/a"
                                                in
                                                case res of
                                                    Ok ( kind, meta, _ ) ->
                                                        [ "via proxy: " ++ kind ++ " " ++ String.fromInt meta.statusCode ++ " " ++ meta.statusText
                                                        , "content-type: " ++ Maybe.withDefault "-" (Dict.get "content-type" meta.headers)
                                                        , "tunnelled: " ++ tunnelled
                                                        ]

                                                    Err e ->
                                                        [ "via proxy: " ++ e, "tunnelled: " ++ tunnelled ]
                                            )
                                )
                    )
        )
