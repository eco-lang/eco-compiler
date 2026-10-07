module ExitWithCodeTest exposing (main)

{-| `System.exitWithCode 3` ends the program at once with status 3
(plans/eco-system-library.md Phase 3 step 3.6, §3.7). Output written before
the exit is kept; the pending one-minute sleep is not waited for.
-}

-- CHECK: before exit
-- CHECK-NOT: after exit
-- EXIT: 3

import Process
import Stream.Log
import System
import Task


type Msg
    = Written
    | Again


main : System.Program () Msg
main =
    System.defineProgram
        { init =
            \env ->
                ( (), Task.perform (\_ -> Written) (Stream.Log.line env.stdout "before exit") )
        , update =
            \msg model ->
                case msg of
                    Written ->
                        ( model
                        , Cmd.batch
                            [ System.exitWithCode 3
                            , Task.perform (\_ -> Again) (Process.sleep 60000)
                            ]
                        )

                    Again ->
                        let
                            _ =
                                Debug.log "after exit" ()
                        in
                        ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
