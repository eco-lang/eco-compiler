module LiveResizeOnlyTest exposing (main)

{-| `Terminal.onResize` is ambient and holds nothing (plans/program-liveness-rule.md X2, LIVE-3,
LIVE_002): the program subscribes, logs `subscribed` and starts nothing else, so its event loop is
empty and it ends. A resize subscription that held would leave it waiting forever (killed by the
watchdog).
-}

-- CHECK: subscribed
-- CHECK-NOT: resized
-- EXIT: 0

import LiveTestHelp as L
import System
import Terminal


type Msg
    = Resized Terminal.Size
    | Logged


main : Platform.Program System.Environment System.Environment Msg
main =
    Platform.worker
        { init = \env -> ( env, L.log env Logged "subscribed" )
        , update =
            \msg env ->
                case msg of
                    Resized _ ->
                        ( env, L.log env Logged "resized" )

                    Logged ->
                        ( env, Cmd.none )
        , subscriptions = \_ -> Terminal.onResize Resized
        }
