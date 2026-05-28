module HttpMultipartTest exposing (main)

-- CHECK: multipart: True

import Http
import Platform
import TestServerConfig


type Msg
    = Got (Result Http.Error String)


main : Program () () Msg
main =
    Platform.worker
        { init = \_ -> ( (), post )
        , update = update
        , subscriptions = \_ -> Sub.none
        }


post : Cmd Msg
post =
    Http.post
        { url = TestServerConfig.baseUrl ++ "/anything"
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
