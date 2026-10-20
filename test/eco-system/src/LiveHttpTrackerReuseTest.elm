module LiveHttpTrackerReuseTest exposing (main)

{-| Reusing a tracker, then cancelling it (plans/program-liveness-rule.md §5.3 tracker reuse).
As stock elm/http does on every backend, a new request with a tracker already in use takes the
tracker over and does not cancel the older request, and `Http.cancel` then withdraws only the
newer one: request 1 (answered after 1.5 s) completes; request 2 (answered after 120 s) is
cancelled and keeps the program running no longer (a request 2 that kept holding would be
stopped by the 60 s watchdog).
-}

-- CHECK: first done
-- CHECK-NOT: second done
-- EXIT: 0

import Http
import Process
import System
import Task
import TestServerConfig


type Msg
    = GotServer TestServerConfig.Server
    | SendSecond TestServerConfig.Server
    | CancelT
    | FirstDone (Result Http.Error String)
    | SecondDone (Result Http.Error String)


get : String -> (Result Http.Error String -> Msg) -> Cmd Msg
get url toMsg =
    Http.request
        { method = "GET"
        , headers = []
        , url = url
        , body = Http.emptyBody
        , expect = Http.expectString toMsg
        , timeout = Nothing
        , tracker = Just "t"
        }


after : Float -> Msg -> Cmd Msg
after ms msg =
    Task.perform (\_ -> msg) (Process.sleep ms)


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
            ( (), Cmd.batch [ get (server.baseUrl ++ "/slow?ms=1500") FirstDone, after 200 (SendSecond server) ] )

        SendSecond server ->
            ( (), Cmd.batch [ get (server.baseUrl ++ "/slow?ms=120000") SecondDone, after 200 CancelT ] )

        CancelT ->
            ( (), Http.cancel "t" )

        FirstDone _ ->
            let
                _ =
                    Debug.log "first done" ()
            in
            ( (), Cmd.none )

        SecondDone _ ->
            let
                _ =
                    Debug.log "second done" ()
            in
            ( (), Cmd.none )
