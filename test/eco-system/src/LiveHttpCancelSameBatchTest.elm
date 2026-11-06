module LiveHttpCancelSameBatchTest exposing (main)

{-| A request and an `Http.cancel` of its tracker in one batch, the request first in the
order the Http manager sees them (plans/program-liveness-rule.md §5.3): as stock elm/http
kills the request's process before it has started, the request is never sent, keeps the
program running no longer, and its response never arrives. The server would answer after
120 s, so a request that kept holding would be stopped by the 60 s watchdog.

A manager sees a batch's commands last first (PORT_005), so the `Http.cancel` comes before
the request in the batch. Until 2026-11-06 the native Http manager saw them first first, the
batch held the request first, and the test was skipped on JS.
-}

-- CHECK: issued
-- CHECK-NOT: response
-- EXIT: 0

import Http
import System
import Task
import TestServerConfig


type Msg
    = GotServer TestServerConfig.Server
    | Issued
    | Response (Result Http.Error String)


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
                [ Http.cancel "b"
                , Http.request
                    { method = "GET"
                    , headers = []
                    , url = server.baseUrl ++ "/slow?ms=120000"
                    , body = Http.emptyBody
                    , expect = Http.expectString Response
                    , timeout = Nothing
                    , tracker = Just "b"
                    }
                , Task.perform (\_ -> Issued) (Task.succeed ())
                ]
            )

        Issued ->
            let
                _ =
                    Debug.log "issued" ()
            in
            ( (), Cmd.none )

        Response _ ->
            let
                _ =
                    Debug.log "response" ()
            in
            ( (), Cmd.none )
