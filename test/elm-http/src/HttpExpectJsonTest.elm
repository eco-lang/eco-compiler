module HttpExpectJsonTest exposing (main)

-- CHECK: json: "GET"

import Http
import Json.Decode as Decode
import Platform
import TestServerConfig


type Msg
    = Got (Result Http.Error String)


main : Program () () Msg
main =
    Platform.worker
        { init = \_ -> ( (), get )
        , update = update
        , subscriptions = \_ -> Sub.none
        }


get : Cmd Msg
get =
    Http.get
        { url = TestServerConfig.baseUrl ++ "/anything"
        , expect = Http.expectJson Got (Decode.field "method" Decode.string)
        }


update : Msg -> () -> ( (), Cmd Msg )
update msg model =
    case msg of
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
