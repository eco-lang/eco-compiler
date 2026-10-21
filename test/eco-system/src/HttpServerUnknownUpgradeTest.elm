module HttpServerUnknownUpgradeTest exposing (main)

{-| An upgrade to a protocol other than WebSocket (plans/eco-system-typed-api.md A3): the request
reaches the program with `upgrade = Just (UnknownUpgrade token)`, the token lower-cased, here
`h2c` and `irc/6.9`. The program answers an ordinary response, which refuses the upgrade; the
server sends it with `Connection: close`.
-}

-- CHECK: server: GET /h2c upgrade Just (UnknownUpgrade h2c)
-- CHECK: server: GET /irc upgrade Just (UnknownUpgrade irc/6.9)
-- CHECK: client: h2c: 200 close not upgraded
-- CHECK: client: irc: 200 close not upgraded
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
    , H.Now (response |> Server.setBody "not upgraded")
    )


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


upgradeTo : String -> String -> String
upgradeTo path token =
    "GET " ++ path ++ " HTTP/1.1" ++ crlf ++ "Host: h" ++ crlf ++ "Upgrade: " ++ token ++ crlf
        ++ "Connection: Upgrade" ++ crlf ++ crlf


client : Server.Server -> Task String (List String)
client server =
    Task.sequence
        [ H.connect server
            |> Task.andThen (H.exchange (upgradeTo "/h2c" "h2c") 1 True)
            |> Task.map (List.map ((++) "h2c: ") >> List.take 1)
        , H.connect server
            |> Task.andThen (H.exchange (upgradeTo "/irc" "IRC/6.9, h2c") 1 True)
            |> Task.map (List.map ((++) "irc: ") >> List.take 1)
        ]
        |> Task.map List.concat


main =
    H.program { options = identity, handler = handler, client = client, exitAtEnd = True }
