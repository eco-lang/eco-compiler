module HttpServerCloseTest exposing (main)

{-| `closeServer` (plans/eco-system-websockets.md §3.4 "closeServer", §4 WS2): the server stops
accepting at once (connecting is refused when the task completes), its idle keep-alive connection
is closed, a request in flight is still answered (with `Connection: close`) and its connection
then closed; a request that arrived at a server nobody subscribes to is answered 503. The port can
be listened on again, closing twice is fine, and the program then ends by itself: closed servers
keep nothing alive.
-}

-- CHECK: server: GET /idle
-- CHECK: server: GET /slow
-- CHECK-NOT: server: GET /parked
-- CHECK: client: idle: 200 keep-alive idle
-- CHECK: client: closeServer: done
-- CHECK: client: connect after close: ECONNREFUSED
-- CHECK: client: idle after close: closed
-- CHECK: client: in flight: 200 close slow
-- CHECK: client: in flight: closed
-- CHECK: client: parked: 503 close
-- CHECK: client: parked: closed
-- CHECK: client: listen again: ok
-- CHECK: client: close twice: done
-- EXIT: 0

import Http.Server as Server
import Http.Server.Response as Response
import HttpServerRawHelp as H
import Socket.Address as Address exposing (Family(..))
import Task exposing (Task)


handler : List String -> Server.Request -> Response.Response -> ( List String, H.Answer )
handler _ request response =
    let
        path =
            request.url.path

        reply =
            response |> Response.setBody (String.dropLeft 1 path)
    in
    ( [ Server.methodToString request.method ++ " " ++ path ]
    , if path == "/slow" then
        H.After 600 reply

      else
        H.Now reply
    )


get : String -> String
get path =
    "GET " ++ path ++ " HTTP/1.1\u{000D}\nHost: h\u{000D}\n\u{000D}\n"


label : String -> List String -> List String
label l =
    List.map (\s -> l ++ ": " ++ s)


client : Server.Server -> Task String (List String)
client server =
    let
        options =
            Server.defaultServerOptions (Address.loopback IPv4) 0
    in
    H.connect server
        |> Task.andThen
            (\idle ->
                H.exchange (get "/idle") 1 False idle
                    |> Task.andThen
                        (\idleLines ->
                            H.connect server
                                |> Task.andThen
                                    (\busy ->
                                        H.sendRaw (get "/slow") busy
                                            |> Task.andThen (\_ -> Server.createServerWith options |> Task.mapError (\(Server.ServerError e) -> e.code))
                                            |> Task.andThen
                                                (\unsubscribed ->
                                                    H.connect unsubscribed
                                                        |> Task.andThen
                                                            (\parked ->
                                                                H.sendRaw (get "/parked") parked
                                                                    |> Task.andThen (\_ -> H.sleep 250)
                                                                    |> Task.andThen (\_ -> Server.closeServer server)
                                                                    |> Task.andThen (\_ -> H.connectCode (Server.serverPort server))
                                                                    |> Task.andThen
                                                                        (\refused ->
                                                                            H.closedOrNot "" idle
                                                                                |> Task.andThen
                                                                                    (\idleClosed ->
                                                                                        H.readResponses 1 busy
                                                                                            |> Task.andThen
                                                                                                (\( resps, rest ) ->
                                                                                                    H.closedOrNot rest busy
                                                                                                        |> Task.map
                                                                                                            (\busyClosed ->
                                                                                                                label "idle" idleLines
                                                                                                                    ++ [ "closeServer: done"
                                                                                                                       , "connect after close: " ++ refused
                                                                                                                       , "idle after close: " ++ idleClosed
                                                                                                                       ]
                                                                                                                    ++ label "in flight" (List.map H.describe resps ++ [ busyClosed ])
                                                                                                            )
                                                                                                )
                                                                                    )
                                                                        )
                                                                    |> Task.andThen
                                                                        (\lines ->
                                                                            Server.closeServer unsubscribed
                                                                                |> Task.andThen (\_ -> H.readResponses 1 parked)
                                                                                |> Task.andThen
                                                                                    (\( resps, rest ) ->
                                                                                        H.closedOrNot rest parked
                                                                                            |> Task.map (\c -> lines ++ label "parked" (List.map H.describe resps ++ [ c ]))
                                                                                    )
                                                                        )
                                                            )
                                                )
                                    )
                        )
            )
        |> Task.andThen
            (\lines ->
                Server.createServerWith { options | port_ = Server.serverPort server }
                    |> Task.andThen (\again -> Server.closeServer again |> Task.map (\_ -> "ok"))
                    |> Task.onError (\(Server.ServerError e) -> Task.succeed (e.code ++ " " ++ e.message))
                    |> Task.andThen
                        (\reopened ->
                            Server.closeServer server
                                |> Task.map (\_ -> lines ++ [ "listen again: " ++ reopened, "close twice: done" ])
                        )
            )


main =
    H.program { options = identity, handler = handler, client = client, exitAtEnd = False }
