module HttpServerRequestTest exposing (main)

{-| `Http.Server` end to end (plans/eco-system-library.md Phase 7 step 7.4):
the program serves its own requests and makes them with elm/http. The server
sees the method, the absolute URL built from the Host header (E.5), the
request headers (the last of duplicated ones wins, E.5) and the body; the
client sees the status, the headers set with `setHeader`/`appendHeader` and
the body.
-}

-- CHECK: server: POST http://127.0.0.1:
-- CHECK: /echo?x=1
-- CHECK: server: method POST path /echo query x=1
-- CHECK: server: x-test hello
-- CHECK: server: x-dup 2
-- CHECK: server: content-type text/plain
-- CHECK: server: body hello server
-- CHECK: client: 201 yes pong
-- CHECK: b pong
-- EXIT: 0

import Dict
import Http
import Http.Server as Server
import Http.Server.Response as Response
import HttpServerTestHelp as Help
import System
import Task


handler : Help.Handler
handler request response =
    let
        header name =
            Dict.get name request.headers |> Maybe.withDefault "-"
    in
    ( [ Server.requestInfo request
      , "method "
            ++ Server.methodToString request.method
            ++ " path "
            ++ request.url.path
            ++ " query "
            ++ Maybe.withDefault "-" request.url.query
      , "x-test " ++ header "X-Test"
      , "x-dup " ++ header "X-Dup"
      , "content-type " ++ header "Content-Type"
      , "body " ++ (Server.bodyAsString request |> Maybe.withDefault "<invalid>")
      ]
    , response
        |> Response.setStatus 201
        |> Response.setHeader "X-Reply" "no"
        |> Response.setHeader "X-Reply" "yes"
        |> Response.appendHeader "X-Multi" "a"
        |> Response.appendHeader "X-Multi" "b"
        |> Response.setBody "pong"
    )


client : String -> Task.Task Never (List String)
client base =
    Help.send
        { method = "POST"
        , headers = [ Http.header "X-Test" "hello", Http.header "X-Dup" "1", Http.header "X-Dup" "2" ]
        , url = base ++ "/echo?x=1"
        , body = Http.stringBody "text/plain" "hello server"
        , header = "x-reply"
        }
        |> Task.andThen
            (\first ->
                Help.send
                    { method = "POST"
                    , headers = []
                    , url = base ++ "/echo?x=1"
                    , body = Http.stringBody "text/plain" "hello server"
                    , header = "x-multi"
                    }
                    |> Task.map (\second -> [ first, second ])
            )


main : System.Program Help.Model Help.Msg
main =
    Help.program { handler = handler, client = client }
