module HttpExpectWhateverTest exposing (main)

-- CHECK: whatever: True

import Http
import Platform
import TestServerConfig


type Msg
    = Done (Result Http.Error ())


main : Program () () Msg
main =
    Platform.worker
        { init = \_ -> ( (), req )
        , update = update
        , subscriptions = \_ -> Sub.none
        }


req : Cmd Msg
req =
    Http.request
        { method = "POST"
        , headers = []
        , url = TestServerConfig.baseUrl ++ "/status/204"
        , body = Http.emptyBody
        , expect = Http.expectWhatever Done
        , timeout = Nothing
        , tracker = Nothing
        }


update : Msg -> () -> ( (), Cmd Msg )
update msg model =
    case msg of
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
