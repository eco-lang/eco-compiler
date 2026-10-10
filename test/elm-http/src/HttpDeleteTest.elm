module HttpDeleteTest exposing (main)

-- CHECK: delete: True

import Http
import Platform
import TestServerConfig
import Task


type Msg
    = Got (Result Http.Error String)
    | GotServer TestServerConfig.Server


main : Program () () Msg
main =
    Platform.worker
        { init = \_ -> ( (), Task.perform GotServer TestServerConfig.server )
        , update = update
        , subscriptions = \_ -> Sub.none
        }


del : TestServerConfig.Server -> Cmd Msg
del server =
    Http.request
        { method = "DELETE"
        , headers = []
        , url = server.baseUrl ++ "/anything"
        , body = Http.emptyBody
        , expect = Http.expectString Got
        , timeout = Nothing
        , tracker = Nothing
        }


update : Msg -> () -> ( (), Cmd Msg )
update msg model =
    case msg of
        GotServer server ->
            ( model, del server )

        Got (Ok body) ->
            let
                _ =
                    Debug.log "delete" (String.contains "\"method\":\"DELETE\"" body)
            in
            ( model, Cmd.none )

        Got (Err _) ->
            let
                _ =
                    Debug.log "delete" False
            in
            ( model, Cmd.none )
