module HttpMultipartTest exposing (main)

-- CHECK: multipart: True

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


post : TestServerConfig.Server -> Cmd Msg
post server =
    Http.post
        { url = server.baseUrl ++ "/anything"
        , body =
            Http.multipartBody
                [ Http.stringPart "alpha" "one"
                , Http.stringPart "beta" "two"
                ]
        , expect = Http.expectString Got
        }


update : Msg -> () -> ( (), Cmd Msg )
update msg model =
    case msg of
        GotServer server ->
            ( model, post server )

        Got (Ok body) ->
            let
                ok =
                    String.contains "multipart/form-data" body
                        && String.contains "name=\\\"alpha\\\"" body
                        && String.contains "one" body
                        && String.contains "name=\\\"beta\\\"" body

                _ =
                    Debug.log "multipart" ok
            in
            ( model, Cmd.none )

        Got (Err _) ->
            let
                _ =
                    Debug.log "multipart" False
            in
            ( model, Cmd.none )
