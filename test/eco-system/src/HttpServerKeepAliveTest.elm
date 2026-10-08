module HttpServerKeepAliveTest exposing (main)

{-| HTTP/1.1 keep-alive (plans/eco-system-websockets.md §3.4, §4 WS2): two requests on one
connection, each answered with `Connection: keep-alive`, the connection staying open between them;
an HTTP/1.0 request is answered with `Connection: close` unless it asks for keep-alive; the
user's `Connection: close` header closes the connection after the response. `serverPort` is the
port the system picked for port 0.
-}

-- CHECK: server: GET /a version Http1_1 upgrade Nothing
-- CHECK: server: GET /b version Http1_1 upgrade Nothing
-- CHECK: server: GET /old version Http1_0 upgrade Nothing
-- CHECK: server: GET /old-ka version Http1_0 upgrade Nothing
-- CHECK: server: GET /bye version Http1_1 upgrade Nothing
-- CHECK: client: port nonzero: True
-- CHECK: client: first: 200 keep-alive a
-- CHECK: client: second: 200 keep-alive b
-- CHECK: client: http/1.0: 200 close old
-- CHECK: client: http/1.0: closed
-- CHECK: client: http/1.0 keep-alive: 200 keep-alive old-ka
-- CHECK: client: user close: 200 close bye
-- CHECK: client: user close: closed
-- EXIT: 0

import Http.Server as Server exposing (HttpVersion(..))
import Http.Server.Response as Response
import HttpServerRawHelp as H
import Task exposing (Task)


version : HttpVersion -> String
version v =
    case v of
        Http1_0 ->
            "Http1_0"

        Http1_1 ->
            "Http1_1"

        Http2 ->
            "Http2"


handler : List String -> Server.Request -> Response.Response -> ( List String, H.Answer )
handler _ request response =
    let
        path =
            request.url.path

        reply =
            response |> Response.setBody (String.dropLeft 1 path)
    in
    ( [ Server.methodToString request.method
            ++ " "
            ++ path
            ++ " version "
            ++ version request.version
            ++ " upgrade "
            ++ Maybe.withDefault "Nothing" request.upgrade
      ]
    , H.Now
        (if path == "/bye" then
            reply |> Response.setHeader "Connection" "close"

         else
            reply
        )
    )


client : Server.Server -> Task String (List String)
client server =
    H.connect server
        |> Task.andThen
            (\conn ->
                H.exchange "GET /a HTTP/1.1\u{000D}\nHost: h\u{000D}\n\u{000D}\n" 1 False conn
                    |> Task.andThen
                        (\first ->
                            H.exchange "GET /b HTTP/1.1\u{000D}\nHost: h\u{000D}\n\u{000D}\n" 1 False conn
                                |> Task.map (\second -> List.map ((++) "first: ") first ++ List.map ((++) "second: ") second)
                        )
            )
        |> Task.andThen
            (\lines ->
                H.connect server
                    |> Task.andThen (H.exchange "GET /old HTTP/1.0\u{000D}\n\u{000D}\n" 1 True)
                    |> Task.map (\more -> lines ++ List.map ((++) "http/1.0: ") more)
            )
        |> Task.andThen
            (\lines ->
                H.connect server
                    |> Task.andThen (H.exchange "GET /old-ka HTTP/1.0\u{000D}\nConnection: keep-alive\u{000D}\n\u{000D}\n" 1 False)
                    |> Task.map (\more -> lines ++ List.map ((++) "http/1.0 keep-alive: ") more)
            )
        |> Task.andThen
            (\lines ->
                H.connect server
                    |> Task.andThen (H.exchange "GET /bye HTTP/1.1\u{000D}\nHost: h\u{000D}\n\u{000D}\n" 1 True)
                    |> Task.map (\more -> lines ++ List.map ((++) "user close: ") more)
            )
        |> Task.map (\lines -> ("port nonzero: " ++ (if Server.serverPort server /= 0 then "True" else "False")) :: lines)


main =
    H.program { options = identity, handler = handler, client = client, exitAtEnd = True }
