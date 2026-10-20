module OnEmptyEventLoopJobQueueTest exposing (main)

{-| A job queue driven by `onEmptyEventLoop` and `System.rearmEmptyEventLoop`
(plans/program-liveness-rule.md §11.1, L-REARM): each delivery pops one job,
logs it and sleeps; when the sleep ends the handler rearms the hook only if
jobs remain. With three jobs the message is delivered exactly three times, and
the program ends after job 3 because nothing rearms the hook then.
-}

-- CHECK: job 1
-- CHECK: job 2
-- CHECK: job 3
-- CHECK: fired: 3
-- CHECK-NOT: fired: 4
-- EXIT: 0

import LiveTestHelp as L
import Process
import System
import Task


type Msg
    = Empty
    | Logged
    | Slept


type alias Model =
    { env : System.Environment
    , jobs : List Int
    , fired : Int
    }


main : Platform.Program System.Environment Model Msg
main =
    Platform.worker
        { init = \env -> ( { env = env, jobs = [ 1, 2, 3 ], fired = 0 }, Cmd.none )
        , update =
            \msg model ->
                case msg of
                    Empty ->
                        let
                            fired =
                                model.fired + 1

                            _ =
                                Debug.log "fired" fired
                        in
                        case model.jobs of
                            job :: rest ->
                                ( { model | jobs = rest, fired = fired }
                                , Cmd.batch
                                    [ L.log model.env Logged ("job " ++ String.fromInt job)
                                    , Task.perform (\_ -> Slept) (Process.sleep 10)
                                    ]
                                )

                            [] ->
                                ( { model | fired = fired }, Cmd.none )

                    Logged ->
                        ( model, Cmd.none )

                    Slept ->
                        ( model
                        , if List.isEmpty model.jobs then
                            Cmd.none

                          else
                            System.rearmEmptyEventLoop
                        )
        , subscriptions = \_ -> System.onEmptyEventLoop Empty
        }
