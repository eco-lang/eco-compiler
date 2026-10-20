module LiveHttpCancelTest exposing (main)

{-| `Http.cancel` withdraws a running request (plans/program-liveness-rule.md §5.3, L5): the
transfer is aborted, the request keeps the program running no longer, and its response is
never delivered. The server answers after 120 s, so a request that kept holding would be
stopped by the 60 s watchdog.
-}

-- CHECK: cancelled
-- CHECK-NOT: response
-- EXIT: 0

import Http
import Process
import System
import Task
import TestServerConfig


type Msg
    = GotServer TestServerConfig.Server
    | Cancel
    | Cancelled
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
                [ Http.request
                    { method = "GET"
                    , headers = []
                    , url = server.baseUrl ++ "/slow?ms=120000"
                    , body = Http.emptyBody
                    , expect = Http.expectString Response
                    , timeout = Nothing
                    , tracker = Just "t"
                    }
                , Task.perform (\_ -> Cancel) (Process.sleep 200)
                ]
            )

        Cancel ->
            ( (), Cmd.batch [ Http.cancel "t", Task.perform (\_ -> Cancelled) (Task.succeed ()) ] )

        Cancelled ->
            let
                _ =
                    Debug.log "cancelled" ()
            in
            ( (), Cmd.none )

        Response _ ->
            let
                _ =
                    Debug.log "response" ()
            in
            ( (), Cmd.none )
