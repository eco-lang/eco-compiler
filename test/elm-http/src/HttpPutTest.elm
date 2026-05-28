module HttpPutTest exposing (main)

-- CHECK: put: True

import Http
import Platform
import TestServerConfig


type Msg
    = Got (Result Http.Error String)


main : Program () () Msg
main =
    Platform.worker
        { init = \_ -> ( (), put )
        , update = update
        , subscriptions = \_ -> Sub.none
        }


put : Cmd Msg
put =
    Http.request
        { method = "PUT"
        , headers = []
        , url = TestServerConfig.baseUrl ++ "/anything"
        , body = Http.stringBody "text/plain" "ping"
        , expect = Http.expectString Got
        , timeout = Nothing
        , tracker = Nothing
        }


update : Msg -> () -> ( (), Cmd Msg )
update msg model =
    case msg of
        Got (Ok body) ->
            let
                _ =
                    Debug.log "put"
                        (String.contains "\"method\":\"PUT\"" body
                            && String.contains "ping" body
                        )
            in
            ( model, Cmd.none )

        Got (Err _) ->
            let
                _ =
                    Debug.log "put" False
            in
            ( model, Cmd.none )
