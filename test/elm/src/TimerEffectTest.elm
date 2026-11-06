module TimerEffectTest exposing (main)

{-| A `Platform.worker` that chains `Process.sleep` timers through `Task.perform` receives each timer message in turn and stops after five.

`init` starts a 100 ms sleep; each time it ends, `update` logs the count and
starts another, until the fifth, when it logs `"done"` and returns `Cmd.none`.
The message is built by a function that ignores the sleep's `()` result.
-}

-- CHECK: TimerEffectTest: "fired 1"
-- CHECK: TimerEffectTest: "fired 2"
-- CHECK: TimerEffectTest: "fired 3"
-- CHECK: TimerEffectTest: "fired 4"
-- CHECK: TimerEffectTest: "fired 5"
-- CHECK: TimerEffectTest: "done"

import Platform
import Process
import Task


type Msg
    = TimerFired


type alias Model =
    { count : Int
    }


sleepCmd : Cmd Msg
sleepCmd =
    Process.sleep 100
        |> Task.perform (\_ -> TimerFired)


init : () -> ( Model, Cmd Msg )
init _ =
    ( { count = 0 }
    , sleepCmd
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        TimerFired ->
            let
                newCount =
                    model.count + 1

                _ =
                    Debug.log "TimerEffectTest" ("fired " ++ String.fromInt newCount)
            in
            if newCount >= 5 then
                let
                    _ =
                        Debug.log "TimerEffectTest" "done"
                in
                ( { model | count = newCount }, Cmd.none )

            else
                ( { model | count = newCount }, sleepCmd )


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.none


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = subscriptions
        }
