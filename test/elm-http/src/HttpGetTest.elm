module HttpGetTest exposing (main)

-- CHECK: getMethod: True

import Http
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
        , expect = Http.expectString Got
        }


update : Msg -> () -> ( (), Cmd Msg )
update msg model =
    case msg of
        Got (Ok body) ->
            let
                _ =
                    Debug.log "getMethod" (String.contains "\"method\":\"GET\"" body)
            in
            ( model, Cmd.none )

        Got (Err _) ->
            let
                _ =
                    Debug.log "getMethod" False
            in
            ( model, Cmd.none )
