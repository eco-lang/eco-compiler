module HttpPostJsonTest exposing (main)

-- CHECK: post: True

import Http
import Json.Encode as Encode
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
        , body = Http.jsonBody (Encode.object [ ( "key", Encode.string "value" ) ])
        , expect = Http.expectString Got
        }


update : Msg -> () -> ( (), Cmd Msg )
update msg model =
    case msg of
        Got (Ok body) ->
            let
                ok =
                    String.contains "\"method\":\"POST\"" body
                        && String.contains "value" body
                        && String.contains "application/json" body

                _ =
                    Debug.log "post" ok
            in
            ( model, Cmd.none )

        Got (Err _) ->
            let
                _ =
                    Debug.log "post" False
            in
            ( model, Cmd.none )
