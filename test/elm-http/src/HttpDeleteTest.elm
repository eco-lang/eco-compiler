module HttpDeleteTest exposing (main)

-- CHECK: delete: True

import Http
import Platform
import TestServerConfig


type Msg
    = Got (Result Http.Error String)


main : Program () () Msg
main =
    Platform.worker
        { init = \_ -> ( (), del )
        , update = update
        , subscriptions = \_ -> Sub.none
        }


del : Cmd Msg
del =
    Http.request
        { method = "DELETE"
        , headers = []
        , url = TestServerConfig.baseUrl ++ "/anything"
        , body = Http.emptyBody
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
                    Debug.log "delete" (String.contains "\"method\":\"DELETE\"" body)
            in
            ( model, Cmd.none )

        Got (Err _) ->
            let
                _ =
                    Debug.log "delete" False
            in
            ( model, Cmd.none )
