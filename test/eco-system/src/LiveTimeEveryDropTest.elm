module LiveTimeEveryDropTest exposing (main)

{-| Dropping a `Time.every` subscription withdraws its scheduled tick
(plans/program-liveness-rule.md §5.3, LIVE-5): once the subscription is gone nothing keeps the
program running, so it ends. The interval is 120 s, so a tick left in flight would be stopped
by the 60 s watchdog.
-}

-- CHECK: dropped
-- CHECK-NOT: tick
-- EXIT: 0

import System
import Task
import Time


type Msg
    = Drop
    | Tick Time.Posix


main : Platform.Program System.Environment Bool Msg
main =
    Platform.worker
        { init = \_ -> ( True, Task.perform (\_ -> Drop) (Task.succeed ()) )
        , update =
            \msg on ->
                case msg of
                    Drop ->
                        let
                            _ =
                                Debug.log "dropped" ()
                        in
                        ( False, Cmd.none )

                    Tick _ ->
                        let
                            _ =
                                Debug.log "tick" ()
                        in
                        ( on, Cmd.none )
        , subscriptions =
            \on ->
                if on then
                    Time.every 120000 Tick

                else
                    Sub.none
        }
