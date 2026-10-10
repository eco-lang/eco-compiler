module HttpExpectJsonTest exposing (main)

-- CHECK: json: "GET"

import Http
import Json.Decode as Decode
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
        { url = server.baseUrl ++ "/anything"
        , expect = Http.expectJson Got (Decode.field "method" Decode.string)
        }


update : Msg -> () -> ( (), Cmd Msg )
update msg model =
    case msg of
        GotServer server ->
            ( model, get server )

        Got (Ok method) ->
            let
                _ =
                    Debug.log "json" method
            in
            ( model, Cmd.none )

        Got (Err _) ->
            let
                _ =
                    Debug.log "json" "ERR"
            in
            ( model, Cmd.none )
