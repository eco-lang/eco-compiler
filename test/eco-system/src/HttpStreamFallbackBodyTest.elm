module HttpStreamFallbackBodyTest exposing (main)

{-| HTTPS-04, part 2 (plans/kernel-lib-bug-fixes.md): a 3xx that curl does not follow, but the
native header callback takes for a followed redirect, keeps its body.

The header callback (S/HttpStream/HttpTransfer.cpp `headerCb`) decides a block is a followed
redirect when it has a non-empty Location, after trimming the name and OWS from the value.
libcurl 7.88's rule differs at two edges: it matches the name only as `Location:` exactly, and
trims every C whitespace character, vertical tab included. Each route here hits one edge:

  - `/redirect-vt-location`: `Location: \v`, blank to curl, not blank to the callback;
  - `/redirect-spaced-location`: `Location : /`, not a Location field to curl.

curl finishes each with the 302 as the final response and the body `moved`, as `curl -L`
shows. The callback posts no head for that block. Before the fix `writeCb` dropped the body as a
redirect body, and `finishTransfer`'s fallback posted the head from the last header block with
an already-ended body: status text and headers survived, the body was lost. Curl passes no body
of a redirect it follows to the write callback, so `writeCb` now takes body bytes that arrive
before the head as the final response's and posts that block's head first.

-}

-- SKIP-JS: node's HTTP parser rejects both header forms (HPE_INVALID_HEADER_TOKEN), so the JS twin gets NetworkError; this pins libcurl's behaviour
-- CHECK: vt kind: BadStatus 302
-- CHECK: vt statusText: [Found]
-- CHECK: vt x-test: kept
-- CHECK: vt body: [moved]
-- CHECK: spaced kind: BadStatus 302
-- CHECK: spaced statusText: [Found]
-- CHECK: spaced x-test: kept
-- CHECK: spaced body: [moved]
-- EXIT: 0

import Dict
import Http
import Http.Method
import Http.Stream
import HttpStreamTestHelp as H
import Stream
import Task exposing (Task)
import TestServerConfig


fetch : TestServerConfig.Server -> String -> String -> Task String (List String)
fetch server label path =
    Http.Stream.task
        { method = Http.Method.GET
        , headers = []
        , url = H.url server path
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
                            Err (label ++ " NetworkError")

                        Http.Timeout_ ->
                            Err (label ++ " Timeout")

                        Http.BadUrl_ u ->
                            Err (label ++ " BadUrl " ++ u)
                )
        , timeout = Just 10000
        }
        |> Task.andThen
            (\( kind, meta, body ) ->
                H.readAllString body
                    |> Task.onError (\e -> Task.succeed ("read error: " ++ Stream.errorToString e))
                    |> Task.map
                        (\text ->
                            [ label ++ " kind: " ++ kind ++ " " ++ String.fromInt meta.statusCode
                            , label ++ " statusText: [" ++ meta.statusText ++ "]"
                            , label ++ " x-test: " ++ Maybe.withDefault "-" (Dict.get "x-test" meta.headers)
                            , label ++ " body: [" ++ text ++ "]"
                            ]
                        )
            )


main =
    H.program
        (\server _ ->
            fetch server "vt" "/redirect-vt-location"
                |> Task.andThen
                    (\vt ->
                        fetch server "spaced" "/redirect-spaced-location"
                            |> Task.map (\spaced -> vt ++ spaced)
                    )
        )
