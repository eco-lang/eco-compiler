module SignalInterruptTest exposing (main)

{-| `System.onSignalInterrupt` (plans/eco-system-library.md Phase 5 step 5.4):
a child shell sends SIGINT to its parent, this program. The subscribed msg
arrives instead of the default action, and the program then exits 0. The run
starts from the second update, after the first effects round has installed
the handler.
-}

-- CHECK: interrupted: True run: ok
-- EXIT: 0

import ProcessTestHelp exposing (noShell)
import Stream.Log
import System
import System.Process as P
import Task


type Msg
    = Start
    | RunDone String
    | Interrupted
    | Logged


type alias Model =
    { env : System.Environment
    , interrupted : Bool
    , run : Maybe String
    }


report : Model -> ( Model, Cmd Msg )
report model =
    case ( model.interrupted, model.run ) of
        ( True, Just r ) ->
            ( model
            , Task.perform (\_ -> Logged)
                (Stream.Log.line model.env.stdout ("interrupted: True run: " ++ r))
            )

        _ ->
            ( model, Cmd.none )


main : System.Program Model Msg
main =
    System.defineProgram
        { init = \env -> ( { env = env, interrupted = False, run = Nothing }, Task.perform (\_ -> Start) (Task.succeed ()) )
        , update =
            \msg model ->
                case msg of
                    Start ->
                        ( model
                        , P.run "sh" [ "-c", "kill -INT $PPID" ] noShell
                            |> Task.map (\_ -> "ok")
                            |> Task.onError (\_ -> Task.succeed "failed")
                            |> Task.perform RunDone
                        )

                    RunDone r ->
                        report { model | run = Just r }

                    Interrupted ->
                        report { model | interrupted = True }

                    Logged ->
                        ( model, Cmd.none )
        , subscriptions = \_ -> System.onSignalInterrupt Interrupted
        }
