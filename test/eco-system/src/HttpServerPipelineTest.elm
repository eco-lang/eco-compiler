module HttpServerPipelineTest exposing (main)

{-| Pipelining (plans/eco-system-websockets.md §3.4 "One request in flight", §4 WS2): a client
sends three requests in one write; the server hands them over one at a time, each only after the
previous one was answered, so a slow handler (the first answer takes 300 ms) holds the later ones
back; the responses arrive in request order on the same connection.
-}

-- CHECK: server: got /1 after []
-- CHECK: server: got /2 after [/1]
-- CHECK: server: got /3 after [/1,/2]
-- CHECK: client: 200 keep-alive one
-- CHECK: client: 200 keep-alive two
-- CHECK: client: 200 keep-alive three
-- EXIT: 0

import Http.Server as Server
import Http.Server.Response as Response
import HttpServerRawHelp as H
import Task exposing (Task)


handler : List String -> Server.Request -> Response.Response -> ( List String, H.Answer )
handler answered request response =
    let
        path =
            request.url.path

        body =
            case path of
                "/1" ->
                    "one"

                "/2" ->
                    "two"

                _ ->
                    "three"

        reply =
            response |> Response.setBody body
    in
    ( [ "got " ++ path ++ " after [" ++ String.join "," answered ++ "]" ]
    , if path == "/1" then
        H.After 300 reply

      else
        H.Now reply
    )


get : String -> String
get path =
    "GET " ++ path ++ " HTTP/1.1\u{000D}\nHost: h\u{000D}\n\u{000D}\n"


client : Server.Server -> Task String (List String)
client server =
    H.connect server
        |> Task.andThen (H.exchange (get "/1" ++ get "/2" ++ get "/3") 3 False)


main =
    H.program { options = identity, handler = handler, client = client, exitAtEnd = True }
