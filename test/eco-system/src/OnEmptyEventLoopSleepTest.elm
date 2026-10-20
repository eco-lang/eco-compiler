module OnEmptyEventLoopSleepTest exposing (main)

{-| A handler that starts a `Process.sleep` and no rearm (plans/program-liveness-rule.md
§11.1, L-REARM): the sleep runs to completion and the program then ends; the message is
not delivered a second time. (The native backend used to deliver it twice, because any
new asynchronous work re-armed the hook.)
-}

-- CHECK: fired: 1
-- CHECK: slept
-- CHECK-NOT: fired: 2
-- EXIT: 0

import Process
import System
import Task


type Msg
    = Empty
    | Slept


main : Platform.Program System.Environment Int Msg
main =
    Platform.worker
        { init = \_ -> ( 0, Cmd.none )
        , update =
            \msg n ->
                case msg of
                    Empty ->
                        let
                            _ =
                                Debug.log "fired" (n + 1)
                        in
                        ( n + 1, Task.perform (\_ -> Slept) (Process.sleep 50) )

                    Slept ->
                        let
                            _ =
                                Debug.log "slept" ()
                        in
                        ( n, Cmd.none )
        , subscriptions = \_ -> System.onEmptyEventLoop Empty
        }
