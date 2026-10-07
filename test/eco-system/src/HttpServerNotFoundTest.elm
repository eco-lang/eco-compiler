module HttpServerNotFoundTest exposing (main)

{-| Two sequential requests to one server (plans/eco-system-library.md
Phase 7 step 7.4): a known path answers 200, an unknown one 404, which
elm/http reports as `BadStatus 404` with `expectString`-style handling. Every
connection is closed after its response (no keep-alive), so the second
request opens a new one.
-}

-- CHECK: server: GET /hello
-- CHECK: server: GET /missing
-- CHECK: client: first 200 text/plain hello
-- CHECK: client: second status 404 text/plain not found
-- CHECK: client: third error BadStatus 404
-- EXIT: 0

import Http
import Http.Server as Server
import Http.Server.Response as Response
import HttpServerTestHelp as Help
import System
import Task


handler : Help.Handler
handler request response =
    ( [ Server.methodToString request.method ++ " " ++ request.url.path ]
    , if request.url.path == "/hello" then
        response
            |> Response.setHeader "Content-Type" "text/plain"
            |> Response.setBody "hello"

      else
        response
            |> Response.setStatus 404
            |> Response.setHeader "Content-Type" "text/plain"
            |> Response.setBody "not found"
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


main : System.Program Help.Model Help.Msg
main =
    Help.program { handler = handler, client = client }
