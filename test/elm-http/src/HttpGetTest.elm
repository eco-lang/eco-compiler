module HttpGetTest exposing (main)

-- CHECK: getMethod: True

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


get : TestServerConfig.Server -> Cmd Msg
get server =
    Http.get
        { url = server.baseUrl ++ "/anything"
        , expect = Http.expectString Got
        }


update : Msg -> () -> ( (), Cmd Msg )
update msg model =
    case msg of
        GotServer server ->
            ( model, get server )

        Got (Ok body) ->
            let
                _ =
                    Debug.log "getMethod" (String.contains "\"method\":\"GET\"" body)
            in
            ( model, Cmd.none )

        Got (Err _) ->
            let
                _ =
                    Debug.log "getMethod" False
            in
            ( model, Cmd.none )
