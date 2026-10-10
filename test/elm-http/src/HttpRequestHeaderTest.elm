module HttpRequestHeaderTest exposing (main)

-- CHECK: header: True

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


req : TestServerConfig.Server -> Cmd Msg
req server =
    Http.request
        { method = "GET"
        , headers = [ Http.header "X-Client" "abc" ]
        , url = server.baseUrl ++ "/echo-headers"
        , body = Http.emptyBody
        , expect = Http.expectString Got
        , timeout = Nothing
        , tracker = Nothing
        }


update : Msg -> () -> ( (), Cmd Msg )
update msg model =
    case msg of
        GotServer server ->
            ( model, req server )

        Got (Ok body) ->
            let
                _ =
                    Debug.log "header" (String.contains "\"x-client\":\"abc\"" body)
            in
            ( model, Cmd.none )

        Got (Err _) ->
            let
                _ =
                    Debug.log "header" False
            in
            ( model, Cmd.none )
