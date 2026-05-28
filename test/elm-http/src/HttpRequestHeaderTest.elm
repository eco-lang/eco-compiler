module HttpRequestHeaderTest exposing (main)

-- CHECK: header: True

import Http
import Platform
import TestServerConfig


type Msg
    = Got (Result Http.Error String)


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
        { method = "GET"
        , headers = [ Http.header "X-Client" "abc" ]
        , url = TestServerConfig.baseUrl ++ "/echo-headers"
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
                    Debug.log "header" (String.contains "\"x-client\":\"abc\"" body)
            in
            ( model, Cmd.none )

        Got (Err _) ->
            let
                _ =
                    Debug.log "header" False
            in
            ( model, Cmd.none )
