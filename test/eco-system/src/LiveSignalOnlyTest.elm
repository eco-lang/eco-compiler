module LiveSignalOnlyTest exposing (main)

{-| Signal subscriptions are ambient and hold nothing (plans/program-liveness-rule.md X1, LIVE-3,
LIVE_002): the program subscribes to `onSignalInterrupt` and `onSignalTerminate`, logs
`subscribed` and starts nothing else, so its event loop is empty and it ends. A signal
subscription that held would leave it waiting forever (killed by the watchdog).
-}

-- CHECK: subscribed
-- CHECK-NOT: signal
-- EXIT: 0

import LiveTestHelp as L
import System


type Msg
    = Signal
    | Logged


main : Platform.Program System.Environment System.Environment Msg
main =
    Platform.worker
        { init = \env -> ( env, L.log env Logged "subscribed" )
        , update =
            \msg env ->
                case msg of
                    Signal ->
                        ( env, L.log env Logged "signal" )

                    Logged ->
                        ( env, Cmd.none )
        , subscriptions = \_ -> Sub.batch [ System.onSignalInterrupt Signal, System.onSignalTerminate Signal ]
        }
