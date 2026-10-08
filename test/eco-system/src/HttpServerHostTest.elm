module HttpServerHostTest exposing (main)

{-| `Host` and the request URL (plans/eco-system-websockets.md §3.4 "Host and URL", base plan
E.5, §4 WS2): an HTTP/1.1 request without `Host`, with two `Host` headers, or with an invalid one
is answered 400 and closed, and never reaches the program. The URL is absolute: `http://` + the
`Host` value + the target; an absolute-form target is kept; an HTTP/1.0 request without `Host`
gets the server's own address.
-}

-- CHECK: server: url http://example.test:8080/p?q=1
-- CHECK: server: url http://star.test/
-- CHECK: server: url http://other.test/abs
-- CHECK: server: fallback True
-- CHECK-NOT: server: url http://h/never
-- CHECK: client: missing: 400 close
-- CHECK: client: missing: closed
-- CHECK: client: duplicate: 400 close
-- CHECK: client: duplicate: closed
-- CHECK: client: invalid: 400 close
-- CHECK: client: invalid: closed
-- CHECK: client: empty: 400 close
-- CHECK: client: host: 200 keep-alive ok
-- CHECK: client: asterisk: 200 keep-alive ok
-- CHECK: client: absolute: 200 keep-alive ok
-- CHECK: client: http/1.0: 200 close ok
-- EXIT: 0

import Http.Server as Server
import Http.Server.Response as Response
import HttpServerRawHelp as H
import Task exposing (Task)


crlf : String
crlf =
    "\u{000D}\n"


bad : Server.Server -> String -> String -> Task String (List String)
bad server label headers =
    H.connect server
        |> Task.andThen (H.exchange ("GET /never HTTP/1.1" ++ crlf ++ headers ++ crlf) 1 True)
        |> Task.map (List.map (\l -> label ++ ": " ++ l))


good : Server.Server -> String -> String -> Task String (List String)
good server label text =
    H.connect server
        |> Task.andThen (H.exchange text 1 False)
        |> Task.map (List.map (\l -> label ++ ": " ++ l))


client : Server.Server -> Task String (List String)
client server =
    Task.sequence
        [ bad server "missing" ""
        , bad server "duplicate" ("Host: h" ++ crlf ++ "Host: h" ++ crlf)
        , bad server "invalid" ("Host: h/x" ++ crlf)
        , bad server "empty" ("Host:" ++ crlf)
        , good server "host" ("GET /p?q=1 HTTP/1.1" ++ crlf ++ "Host: example.test:8080" ++ crlf ++ crlf)
        , good server "asterisk" ("OPTIONS * HTTP/1.1" ++ crlf ++ "Host: star.test" ++ crlf ++ crlf)
        , good server "absolute" ("GET http://other.test/abs HTTP/1.1" ++ crlf ++ "Host: other.test" ++ crlf ++ crlf)
        , good server "http/1.0" ("GET /fallback HTTP/1.0" ++ crlf ++ crlf)
        ]
        |> Task.map List.concat


main =
    H.program { options = identity, handler = handler, client = client, exitAtEnd = True }


handler : List String -> Server.Request -> Response.Response -> ( List String, H.Answer )
handler _ request response =
    let
        url =
            -- requestInfo is "<METHOD> <url>"
            Server.requestInfo request |> String.split " " |> List.drop 1 |> String.join " "

        line =
            if request.url.path == "/fallback" then
                "fallback "
                    ++ (if request.url.host == "127.0.0.1" && request.url.port_ /= Nothing then
                            "True"

                        else
                            "False " ++ url
                       )

            else
                "url " ++ url
    in
    ( [ line ], H.Now (response |> Response.setBody "ok") )
