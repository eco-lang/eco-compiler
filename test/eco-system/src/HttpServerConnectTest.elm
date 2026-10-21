module HttpServerConnectTest exposing (main)

{-| `CONNECT` (plans/eco-system-websockets.md §3.4 "Upgrade and CONNECT", §4 WS2): the request
reaches the program as an ordinary request (method `CONNECT`, no upgrade token); whatever the
program answers is sent with `Connection: close` and the connection is closed afterwards: bytes
after the request are never parsed or tunnelled.
-}

-- CHECK: server: CONNECT upgrade Nothing
-- CHECK-NOT: server: GET /hidden
-- CHECK: client: connect: 200 close no tunnel
-- CHECK: client: connect: closed
-- EXIT: 0

import Http.Method
import Http.Server as Server
import HttpServerRawHelp as H
import Task exposing (Task)


handler : List String -> Server.Request -> Server.Response -> ( List String, H.Answer )
handler _ request response =
    ( [ Http.Method.toString request.method
            ++ " upgrade "
            ++ upgradeString request.upgrade
      ]
    , H.Now (response |> Server.setBody "no tunnel")
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
    H.connect server
        |> Task.andThen
            (H.exchange
                ("CONNECT example.test:443 HTTP/1.1" ++ crlf ++ "Host: example.test:443" ++ crlf ++ crlf
                    ++ "GET /hidden HTTP/1.1" ++ crlf ++ "Host: h" ++ crlf ++ crlf
                )
                1
                True
            )
        |> Task.map (List.map ((++) "connect: "))


main =
    H.program { options = identity, handler = handler, client = client, exitAtEnd = True }
