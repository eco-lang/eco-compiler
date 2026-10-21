module HttpServerNotFoundTest exposing (main)

{-| Two sequential requests to one server (plans/eco-system-library.md
Phase 7 step 7.4): a known path answers 200, an unknown one 404, which
elm/http reports as `BadStatus 404` with `expectString`-style handling. Since
plans/eco-system-websockets.md WS2 connections are kept alive, so the client
may send the later requests on the first connection.
-}

-- CHECK: server: GET /hello
-- CHECK: server: GET /missing
-- CHECK: client: first 200 text/plain hello
-- CHECK: client: second status 404 text/plain not found
-- CHECK: client: third error BadStatus 404
-- EXIT: 0

import Http
import Http.Method
import Http.Server as Server
import HttpServerTestHelp as Help
import System
import Task


handler : Help.Handler
handler request response =
    ( [ Http.Method.toString request.method ++ " " ++ request.url.path ]
    , if request.url.path == "/hello" then
        response
            |> Server.setHeader "Content-Type" "text/plain"
            |> Server.setBody "hello"

      else
        response
            |> Server.setStatus 404
            |> Server.setHeader "Content-Type" "text/plain"
            |> Server.setBody "not found"
    )


client : String -> Task.Task Never (List String)
client base =
    Help.get (base ++ "/hello")
        |> Task.andThen
            (\first ->
                Help.get (base ++ "/missing")
                    |> Task.andThen
                        (\second ->
                            Http.task
                                { method = "GET"
                                , headers = []
                                , url = base ++ "/missing"
                                , body = Http.emptyBody
                                , resolver =
                                    Http.stringResolver
                                        (\r ->
                                            case r of
                                                Http.GoodStatus_ _ body ->
                                                    Ok body

                                                Http.BadStatus_ meta _ ->
                                                    Err (Http.BadStatus meta.statusCode)

                                                _ ->
                                                    Err Http.NetworkError
                                        )
                                , timeout = Just 20000
                                }
                                |> Task.map (\b -> "ok " ++ b)
                                |> Task.onError (\e -> Task.succeed ("error " ++ Help.httpErrorToString e))
                                |> Task.map (\third -> [ "first " ++ first, "second " ++ second, "third " ++ third ])
                        )
            )


main : Platform.Program System.Environment Help.Model Help.Msg
main =
    Help.program { handler = handler, client = client }
