module OnEmptyEventLoopResubscribeTest exposing (main)

{-| The armed bit is per program run (plans/program-liveness-rule.md §7.2, §11.1): the
message is delivered, the handler unsubscribes and sleeps, and on waking subscribes again
without a rearm. The new subscription does not receive the message, and the program ends.
-}

-- CHECK: fired: 1
-- CHECK: woke
-- CHECK-NOT: fired: 2
-- EXIT: 0

import Process
import System
import Task


type Msg
    = Empty
    | Woke


type alias Model =
    { subscribed : Bool
    , fired : Int
    }


main : Platform.Program System.Environment Model Msg
main =
    Platform.worker
        { init = \_ -> ( { subscribed = True, fired = 0 }, Cmd.none )
        , update =
            \msg model ->
                case msg of
                    Empty ->
                        let
                            _ =
                                Debug.log "fired" (model.fired + 1)
                        in
                        ( { model | subscribed = False, fired = model.fired + 1 }
                        , Task.perform (\_ -> Woke) (Process.sleep 50)
                        )

                    Woke ->
                        let
                            _ =
                                Debug.log "woke" ()
                        in
                        ( { model | subscribed = True }, Cmd.none )
        , subscriptions =
            \model ->
                if model.subscribed then
                    System.onEmptyEventLoop Empty

                else
                    Sub.none
        }
