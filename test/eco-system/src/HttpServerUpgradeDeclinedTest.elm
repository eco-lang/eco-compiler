module HttpServerUpgradeDeclinedTest exposing (main)

{-| An upgrade request answered with an ordinary response (plans/eco-system-websockets.md §3.4
"Upgrade and CONNECT", §4 WS2): the request reaches the program with `upgrade = Just
"websocket"` (the first token of `Upgrade`, lower-cased, since `Connection` lists `upgrade`); the
program answers 426, which the server sends with `Connection: close`, then closes the connection
(bytes the client sent after the request are never parsed). A request whose `Connection` does not
list `upgrade` is an ordinary request (`upgrade = Nothing`).
-}

-- CHECK: server: GET /ws upgrade Just websocket
-- CHECK: server: GET /plain upgrade Nothing
-- CHECK-NOT: server: GET /hidden
-- CHECK: client: declined: 426 close upgrade required
-- CHECK: client: declined: closed
-- CHECK: client: not an upgrade: 200 keep-alive plain
-- EXIT: 0

import Http.Server as Server
import Http.Server.Response as Response
import HttpServerRawHelp as H
import Task exposing (Task)


handler : List String -> Server.Request -> Response.Response -> ( List String, H.Answer )
handler _ request response =
    ( [ Server.methodToString request.method
            ++ " "
            ++ request.url.path
            ++ " upgrade "
            ++ (request.upgrade |> Maybe.map ((++) "Just ") |> Maybe.withDefault "Nothing")
      ]
    , H.Now
        (case request.upgrade of
            Just _ ->
                response
                    |> Response.setStatus 426
                    |> Response.setHeader "Upgrade" "websocket"
                    |> Response.setBody "upgrade required"

            Nothing ->
                response |> Response.setBody "plain"
        )
    )


crlf : String
crlf =
    "\u{000D}\n"


client : Server.Server -> Task String (List String)
client server =
    Task.sequence
        [ H.connect server
            |> Task.andThen
                (H.exchange
                    ("GET /ws HTTP/1.1" ++ crlf ++ "Host: h" ++ crlf ++ "Upgrade: WebSocket, other/1" ++ crlf
                        ++ "Connection: keep-alive, Upgrade" ++ crlf ++ "Sec-WebSocket-Version: 13" ++ crlf ++ crlf
                        ++ "GET /hidden HTTP/1.1" ++ crlf ++ "Host: h" ++ crlf ++ crlf
                    )
                    1
                    True
                )
            |> Task.map (List.map ((++) "declined: "))
        , H.connect server
            |> Task.andThen
                (H.exchange ("GET /plain HTTP/1.1" ++ crlf ++ "Host: h" ++ crlf ++ "Upgrade: websocket" ++ crlf ++ crlf) 1 False)
            |> Task.map (List.map ((++) "not an upgrade: "))
        ]
        |> Task.map List.concat


main =
    H.program { options = identity, handler = handler, client = client, exitAtEnd = True }
