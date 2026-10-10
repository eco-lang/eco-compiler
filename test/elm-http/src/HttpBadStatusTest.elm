module HttpBadStatusTest exposing (main)

-- CHECK: err: "BadStatus 404"

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


get : TestServerConfig.Server -> Cmd Msg
get server =
    Http.get
        { url = server.baseUrl ++ "/status/404"
        , expect = Http.expectString Got
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
            ( model, get server )

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
