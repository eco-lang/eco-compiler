module HttpTaskTest exposing (main)

-- CHECK: task: True

import Http
import Platform
import Task exposing (Task)
import TestServerConfig


type Msg
    = Got (Result String String)
    | GotServer TestServerConfig.Server


main : Program () () Msg
main =
    Platform.worker
        { init = \_ -> ( (), Task.perform GotServer TestServerConfig.server )
        , update = update
        , subscriptions = \_ -> Sub.none
        }


fetch : TestServerConfig.Server -> Task String String
fetch server =
    Http.task
        { method = "GET"
        , headers = []
        , url = server.baseUrl ++ "/anything"
        , body = Http.emptyBody
        , resolver = Http.stringResolver resolve
        , timeout = Nothing
        }


resolve : Http.Response String -> Result String String
resolve response =
    case response of
        Http.GoodStatus_ _ body ->
            Ok body

        _ ->
            Err "fail"


update : Msg -> () -> ( (), Cmd Msg )
update msg model =
    case msg of
        GotServer server ->
            ( model, Task.attempt Got (fetch server) )

        Got (Ok body) ->
            let
                _ =
                    Debug.log "task" (String.contains "\"method\":\"GET\"" body)
            in
            ( model, Cmd.none )

        Got (Err _) ->
            let
                _ =
                    Debug.log "task" False
            in
            ( model, Cmd.none )
