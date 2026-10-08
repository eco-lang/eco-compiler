module HttpServerOneXxTest exposing (main)

{-| A final status 100–199 cannot be a response (plans/eco-system-websockets.md §3.4 "Responses",
§4 WS2): the program answering 103 (or 101 outside a WebSocket upgrade) sends 500 instead, with
an empty body; the connection stays usable.
-}

-- CHECK: server: GET /early-hints
-- CHECK: server: GET /switching
-- CHECK: client: 103: 500 keep-alive
-- CHECK: client: 101: 500 keep-alive
-- CHECK: client: after: 200 keep-alive fine
-- EXIT: 0

import Http.Server as Server
import Http.Server.Response as Response
import HttpServerRawHelp as H
import Task exposing (Task)


handler : List String -> Server.Request -> Response.Response -> ( List String, H.Answer )
handler _ request response =
    ( [ Server.methodToString request.method ++ " " ++ request.url.path ]
    , H.Now
        (case request.url.path of
            "/early-hints" ->
                response |> Response.setStatus 103 |> Response.setBody "hints"

            "/switching" ->
                response |> Response.setStatus 101 |> Response.setHeader "Upgrade" "websocket"

            _ ->
                response |> Response.setBody "fine"
        )
    )


get : String -> String
get path =
    "GET " ++ path ++ " HTTP/1.1\u{000D}\nHost: h\u{000D}\n\u{000D}\n"


client : Server.Server -> Task String (List String)
client server =
    H.connect server
        |> Task.andThen
            (\conn ->
                Task.sequence
                    [ H.exchange (get "/early-hints") 1 False conn |> Task.map (List.map ((++) "103: "))
                    , H.exchange (get "/switching") 1 False conn |> Task.map (List.map ((++) "101: "))
                    , H.exchange (get "/after") 1 False conn |> Task.map (List.map ((++) "after: "))
                    ]
            )
        |> Task.map List.concat


main =
    H.program { options = identity, handler = handler, client = client, exitAtEnd = True }
