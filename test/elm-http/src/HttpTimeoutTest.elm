module HttpTimeoutTest exposing (main)

-- CHECK: err: "Timeout"

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
        , headers = []
        , url = TestServerConfig.baseUrl ++ "/slow?ms=3000"
        , body = Http.emptyBody
        , expect = Http.expectString Got
        , timeout = Just 100
        , tracker = Nothing
        }


errLabel : Http.Error -> String
errLabel err =
    case err of
        Http.BadUrl _ ->
            "BadUrl"

        Http.Timeout ->
            "Timeout"

        Http.NetworkError ->
            "NetworkError"

        Http.BadStatus code ->
            "BadStatus " ++ String.fromInt code

        Http.BadBody _ ->
            "BadBody"


update : Msg -> () -> ( (), Cmd Msg )
update msg model =
    case msg of
        Got (Ok _) ->
            let
                _ =
                    Debug.log "err" "Ok"
            in
            ( model, Cmd.none )

        Got (Err e) ->
            let
                _ =
                    Debug.log "err" (errLabel e)
            in
            ( model, Cmd.none )
