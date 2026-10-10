module HttpExpectWhateverTest exposing (main)

-- CHECK: whatever: True

import Http
import Platform
import TestServerConfig
import Task


type Msg
    = Done (Result Http.Error ())
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
        { method = "POST"
        , headers = []
        , url = server.baseUrl ++ "/status/204"
        , body = Http.emptyBody
        , expect = Http.expectWhatever Done
        , timeout = Nothing
        , tracker = Nothing
        }


update : Msg -> () -> ( (), Cmd Msg )
update msg model =
    case msg of
        GotServer server ->
            ( model, req server )

        Done (Ok ()) ->
            let
                _ =
                    Debug.log "whatever" True
            in
            ( model, Cmd.none )

        Done (Err _) ->
            let
                _ =
                    Debug.log "whatever" False
            in
            ( model, Cmd.none )
