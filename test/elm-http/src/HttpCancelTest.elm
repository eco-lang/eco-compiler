module HttpCancelTest exposing (main)

-- CHECK: cancelled: True

import Http
import Platform
import Process
import Task
import TestServerConfig


type Msg
    = GotProgress Http.Progress
    | DoCancel
    | CheckDone
    | Got (Result Http.Error String)


type alias Model =
    { gotResponse : Bool }


main : Program () Model Msg
main =
    Platform.worker
        { init = \_ -> ( Model False, Cmd.batch [ get, after 100 DoCancel ] )
        , update = update
        , subscriptions = \_ -> Http.track "p" GotProgress
        }


after : Float -> Msg -> Cmd Msg
after ms msg =
    Task.perform (\_ -> msg) (Process.sleep ms)


get : Cmd Msg
get =
    Http.request
        { method = "GET"
        , headers = []
        , url = TestServerConfig.baseUrl ++ "/drip?bytes=8192&ms=1500"
        , body = Http.emptyBody
        , expect = Http.expectString Got
        , timeout = Nothing
        , tracker = Just "p"
        }


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        GotProgress _ ->
            ( model, Cmd.none )

        DoCancel ->
            -- The request's binding has long since registered its tracker by
            -- 100 ms, so this cancel marks the in-flight request for
            -- drop-delivery. Then wait past the request's completion (~1.5 s)
            -- and assert no response message ever arrived.
            ( model, Cmd.batch [ Http.cancel "p", after 2500 CheckDone ] )

        Got _ ->
            ( { model | gotResponse = True }, Cmd.none )

        CheckDone ->
            let
                _ =
                    Debug.log "cancelled" (not model.gotResponse)
            in
            ( model, Cmd.none )
