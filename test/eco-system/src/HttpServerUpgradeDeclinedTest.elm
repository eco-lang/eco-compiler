module HttpServerUpgradeDeclinedTest exposing (main)

{-| An upgrade request answered with an ordinary response (plans/eco-system-websockets.md §3.4
"Upgrade and CONNECT", §4 WS2): the request reaches the program with `upgrade = Just
WebSocketUpgrade` (the first token of `Upgrade`, lower-cased, since `Connection` lists `upgrade`); the
program answers 426, which the server sends with `Connection: close`, then closes the connection
(bytes the client sent after the request are never parsed). A request whose `Connection` does not
list `upgrade` is an ordinary request (`upgrade = Nothing`).
-}

-- CHECK: server: GET /ws upgrade Just WebSocketUpgrade
-- CHECK: server: GET /plain upgrade Nothing
-- CHECK-NOT: server: GET /hidden
-- CHECK: client: declined: 426 close upgrade required
-- CHECK: client: declined: closed
-- CHECK: client: not an upgrade: 200 keep-alive plain
-- EXIT: 0

import Http.Method
import Http.Server as Server
import HttpServerRawHelp as H
import Task exposing (Task)


handler : List String -> Server.Request -> Server.Response -> ( List String, H.Answer )
handler _ request response =
    ( [ Http.Method.toString request.method
            ++ " "
            ++ request.url.path
            ++ " upgrade "
            ++ upgradeString request.upgrade
      ]
    , H.Now
        (case request.upgrade of
            Just _ ->
                response
                    |> Server.setStatus 426
                    |> Server.setHeader "Upgrade" "websocket"
                    |> Server.setBody "upgrade required"

            Nothing ->
                response |> Server.setBody "plain"
        )
    )


{-| `Nothing`, `Just WebSocketUpgrade` or `Just (UnknownUpgrade <token>)`.
-}
upgradeString : Maybe Server.Upgrade -> String
upgradeString upgrade =
    case upgrade of
        Nothing ->
            "Nothing"

        Just Server.WebSocketUpgrade ->
            "Just WebSocketUpgrade"

        Just (Server.UnknownUpgrade token) ->
            "Just (UnknownUpgrade " ++ token ++ ")"


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
