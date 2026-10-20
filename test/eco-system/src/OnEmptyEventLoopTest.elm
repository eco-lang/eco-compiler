module OnEmptyEventLoopTest exposing (main)

{-| `System.onEmptyEventLoop` (Node `beforeExit`, plans/eco-system-library.md
§3.7; decision L-REARM, plans/program-liveness-rule.md §7): fires once; the
IO its handler starts runs to completion, then the program ends. The IO does
not arm the hook again, so there is no second delivery, although the
subscription stays active throughout.
-}

-- CHECK: fired: 1
-- CHECK: io from first fire
-- CHECK-NOT: fired: 2
-- EXIT: 0

import Stream
import System
import Task


type Msg
    = Empty
    | Logged


type alias Model =
    { env : System.Environment
    , fired : Int
    }


main : Platform.Program System.Environment Model Msg
main =
    Platform.worker
        { init = \env -> ( { env = env, fired = 0 }, Cmd.none )
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
                        ( { model | fired = fired }
                        , if fired == 1 then
                            Task.perform (\_ -> Logged) (Stream.logLine "io from first fire" model.env.stdout)

                          else
                            Cmd.none
                        )

                    Logged ->
                        ( model, Cmd.none )
        , subscriptions = \_ -> System.onEmptyEventLoop Empty
        }
