module HttpTaskTest exposing (main)

-- CHECK: task: True

import Http
import Platform
import Task exposing (Task)
import TestServerConfig


type Msg
    = Got (Result String String)


main : Program () () Msg
main =
    Platform.worker
        { init = \_ -> ( (), Task.attempt Got fetch )
        , update = update
        , subscriptions = \_ -> Sub.none
        }


fetch : Task String String
fetch =
    Http.task
        { method = "GET"
        , headers = []
        , url = TestServerConfig.baseUrl ++ "/anything"
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
