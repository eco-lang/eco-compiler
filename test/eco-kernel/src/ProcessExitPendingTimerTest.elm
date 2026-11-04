module ProcessExitPendingTimerTest exposing (main)

{-| CRASH-01 (plans/kernel-lib-bug-fixes.md), POSIX regression pin: `Eco.Process.exit
(ExitFailure 3)` ends the program with status 3 while a long timer is still pending (the timer
service thread is alive). CRASH-01 itself is a Windows-only hang (`::exit` with live service
threads); no test reaches it here. This pins today's POSIX behaviour across the
`eco_terminate_process` refactor and passes today.

-}

-- CHECK: before exit
-- CHECK-NOT: after exit
-- EXIT: 3

import Eco.Process as P
import Process
import Task


type Msg
    = Exit
    | Late


main : Program () () Msg
main =
    Platform.worker
        { init =
            \_ ->
                ( ()
                , Cmd.batch
                    [ Task.perform (\_ -> Exit) (Process.sleep 10)
                    , Task.perform (\_ -> Late) (Process.sleep 60000)
                    ]
                )
        , update =
            \msg model ->
                case msg of
                    Exit ->
                        let
                            _ =
                                Debug.log "before exit" ()
                        in
                        ( model, Task.perform (\_ -> Late) (P.exit (P.ExitFailure 3)) )

                    Late ->
                        let
                            _ =
                                Debug.log "after exit" ()
                        in
                        ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
