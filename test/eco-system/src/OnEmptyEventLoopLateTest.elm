module OnEmptyEventLoopLateTest exposing (main)

{-| A first `onEmptyEventLoop` subscription made late, after a sleep
(plans/program-liveness-rule.md §7.2, §11.1): the hook starts armed, so the message
is delivered once at the next empty event loop, and not again.
-}

-- CHECK: woke
-- CHECK: fired: 1
-- CHECK-NOT: fired: 2
-- EXIT: 0

import Process
import System
import Task


type Msg
    = Woke
    | Empty


type alias Model =
    { subscribed : Bool
    , fired : Int
    }


main : Platform.Program System.Environment Model Msg
main =
    Platform.worker
        { init = \_ -> ( { subscribed = False, fired = 0 }, Task.perform (\_ -> Woke) (Process.sleep 50) )
        , update =
            \msg model ->
                case msg of
                    Woke ->
                        let
                            _ =
                                Debug.log "woke" ()
                        in
                        ( { model | subscribed = True }, Cmd.none )

                    Empty ->
                        let
                            _ =
                                Debug.log "fired" (model.fired + 1)
                        in
                        ( { model | fired = model.fired + 1 }, Cmd.none )
        , subscriptions =
            \model ->
                if model.subscribed then
                    System.onEmptyEventLoop Empty

                else
                    Sub.none
        }
