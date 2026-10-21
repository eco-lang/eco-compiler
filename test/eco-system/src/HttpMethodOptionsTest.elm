module HttpMethodOptionsTest exposing (main)

{-| `Http.Method` end to end (plans/eco-system-typed-api.md A1, A2): an `Http.Stream.task` client
sends `OPTIONS`, `UNKNOWN "PROPFIND"` and `GET` to an `Http.Server`, which sees `OPTIONS` as its
own constructor (it used to arrive as `UNKNOWN "OPTIONS"`) and an unlisted method as `UNKNOWN`
with its name.
-}

-- CHECK: server: OPTIONS constructor /o
-- CHECK: server: UNKNOWN PROPFIND /p
-- CHECK: server: GET constructor /g
-- CHECK: client: OPTIONS 200 OPTIONS
-- CHECK: client: PROPFIND 200 PROPFIND
-- CHECK: client: GET 200 GET
-- EXIT: 0

import Http
import Http.Method exposing (Method(..))
import Http.Server as Server
import Http.Stream
import HttpServerTestHelp as Help
import Stream
import System
import Task exposing (Task)


handler : Help.Handler
handler request response =
    let
        seen =
            case request.method of
                OPTIONS ->
                    "OPTIONS constructor"

                GET ->
                    "GET constructor"

                UNKNOWN name ->
                    "UNKNOWN " ++ name

                other ->
                    "unexpected " ++ Http.Method.toString other
    in
    ( [ seen ++ " " ++ request.url.path ]
    , response |> Server.setBody (Http.Method.toString request.method)
    )


{-| Sends `method` with `Http.Stream.task` and reads the body the server answers with: its method.
-}
call : String -> Method -> String -> Task Never String
call base method path =
    Http.Stream.task
        { method = method
        , headers = []
        , url = base ++ path
        , body = Http.Stream.emptyBody
        , resolver =
            Http.Stream.streamResolver
                (\r ->
                    case r of
                        Http.GoodStatus_ meta stream ->
                            Ok ( meta.statusCode, stream )

                        _ ->
                            Err "unexpected response"
                )
        , timeout = Just 20000
        }
        |> Task.andThen
            (\( status, stream ) ->
                Stream.readString stream
                    |> Task.mapError Stream.errorToString
                    |> Task.map (\body -> Http.Method.toString method ++ " " ++ String.fromInt status ++ " " ++ body)
            )
        |> Task.onError (\e -> Task.succeed (Http.Method.toString method ++ " error " ++ e))


client : String -> Task Never (List String)
client base =
    Task.sequence
        [ call base OPTIONS "/o"
        , call base (UNKNOWN "PROPFIND") "/p"
        , call base GET "/g"
        ]


main : Platform.Program System.Environment Help.Model Help.Msg
main =
    Help.program { handler = handler, client = client }
