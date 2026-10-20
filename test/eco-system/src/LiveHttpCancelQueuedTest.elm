module LiveHttpCancelQueuedTest exposing (main)

{-| `Http.cancel` withdraws a request that has not started (plans/program-liveness-rule.md
§5.3, N2): request A (answered after 1.5 s) is sent first; B (answered after 120 s, tracker
"b") is cancelled 200 ms later. On the native backend one worker sends the requests in
turn, so B is still queued behind A and is claimed before it starts. A completes, B's
response never arrives, and the program ends; a B that kept holding would be stopped by the
60 s watchdog.
-}

-- CHECK: a done
-- CHECK-NOT: b response
-- EXIT: 0

import Http
import Process
import System
import Task
import TestServerConfig


type Msg
    = GotServer TestServerConfig.Server
    | CancelB
    | ADone (Result Http.Error String)
    | BResponse (Result Http.Error String)


get : String -> Maybe String -> (Result Http.Error String -> Msg) -> Cmd Msg
get url tracker toMsg =
    Http.request
        { method = "GET"
        , headers = []
        , url = url
        , body = Http.emptyBody
        , expect = Http.expectString toMsg
        , timeout = Nothing
        , tracker = tracker
        }


main : Platform.Program System.Environment () Msg
main =
    Platform.worker
        { init = \_ -> ( (), Task.perform GotServer TestServerConfig.server )
        , update = update
        , subscriptions = \_ -> Sub.none
        }


update : Msg -> () -> ( (), Cmd Msg )
update msg () =
    case msg of
        GotServer server ->
            ( ()
            , Cmd.batch
                [ get (server.baseUrl ++ "/slow?ms=1500") Nothing ADone
                , get (server.baseUrl ++ "/slow?ms=120000") (Just "b") BResponse
                , Task.perform (\_ -> CancelB) (Process.sleep 200)
                ]
            )

        CancelB ->
            ( (), Http.cancel "b" )

        ADone _ ->
            let
                _ =
                    Debug.log "a done" ()
            in
            ( (), Cmd.none )

        BResponse _ ->
            let
                _ =
                    Debug.log "b response" ()
            in
            ( (), Cmd.none )
