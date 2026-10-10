module HttpTrackChunkedTest exposing (main)

-- CHECK: chunked: True

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
    , sawNothing : Bool
    }


main : Program () Model Msg
main =
    Platform.worker
        { init = \_ -> ( Model 0 False, Task.perform GotServer TestServerConfig.server )
        , update = update
        , subscriptions = \_ -> Http.track "c" GotProgress
        }


get : TestServerConfig.Server -> Cmd Msg
get server =
    Http.request
        { method = "GET"
        , headers = []
        , url = server.baseUrl ++ "/drip-chunked?bytes=2048&ms=400"
        , body = Http.emptyBody
        , expect = Http.expectString Got
        , timeout = Nothing
        , tracker = Just "c"
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
                        , sawNothing =
                            model.sawNothing || (r.size == Nothing)
                      }
                    , Cmd.none
                    )

        Got _ ->
            let
                ok =
                    (model.receivingTicks >= 1) && model.sawNothing

                _ =
                    Debug.log "chunked" ok
            in
            ( model, Cmd.none )
