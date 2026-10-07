module OnEmptyEventLoopTest exposing (main)

{-| `System.onEmptyEventLoop` (Node `beforeExit`, plans/eco-system-library.md
§3.7): the msg arrives when the program runs out of work. The first delivery
starts IO (a stdout write), so the program runs out of work again and the msg
is delivered a second time; that delivery starts nothing, so the program then
exits. The subscription stays active throughout.
-}

-- CHECK: fired: 1
-- CHECK: io from first fire
-- CHECK: fired: 2
-- CHECK-NOT: fired: 3
-- EXIT: 0

import Stream.Log
import System
import Task


type Msg
    = Empty
    | Logged


type alias Model =
    { env : System.Environment
    , fired : Int
    }


main : System.Program Model Msg
main =
    System.defineProgram
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
                            Task.perform (\_ -> Logged) (Stream.Log.line model.env.stdout "io from first fire")

                          else
                            Cmd.none
                        )

                    Logged ->
                        ( model, Cmd.none )
        , subscriptions = \_ -> System.onEmptyEventLoop Empty
        }
