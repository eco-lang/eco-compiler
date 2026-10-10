module HttpTimeoutTest exposing (main)

-- CHECK: err: "Timeout"

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
        , headers = []
        , url = server.baseUrl ++ "/slow?ms=3000"
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
        GotServer server ->
            ( model, req server )

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
