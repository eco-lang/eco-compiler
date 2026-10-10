module HttpTrackProgressTest exposing (main)

-- CHECK: track: True

import Http
import Platform
import TestServerConfig
import Task


type Msg
    = GotProgress Http.Progress
    | GotServer TestServerConfig.Server
    | Got (Result Http.Error String)


type alias Model =
    { receivingTicks : Int
    , lastReceived : Int
    , lastSize : Int
    }


main : Program () Model Msg
main =
    Platform.worker
        { init = \_ -> ( Model 0 0 0, Task.perform GotServer TestServerConfig.server )
        , update = update
        , subscriptions = \_ -> Http.track "p" GotProgress
        }


get : TestServerConfig.Server -> Cmd Msg
get server =
    Http.request
        { method = "GET"
        , headers = []
        , url = server.baseUrl ++ "/drip?bytes=2048&ms=400"
        , body = Http.emptyBody
        , expect = Http.expectString Got
        , timeout = Nothing
        , tracker = Just "p"
        }


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        GotServer server ->
            ( model, get server )

        GotProgress progress ->
            case progress of
                Http.Sending _ ->
                    ( model, Cmd.none )

                Http.Receiving r ->
                    ( { model
                        | receivingTicks = model.receivingTicks + 1
                        , lastReceived = r.received
                        , lastSize = Maybe.withDefault -1 r.size
                      }
                    , Cmd.none
                    )

        Got _ ->
            let
                ok =
                    (model.receivingTicks >= 1)
                        && (model.lastReceived == model.lastSize)
                        && (model.lastSize == 2048)

                _ =
                    Debug.log "track" ok
            in
            ( model, Cmd.none )
