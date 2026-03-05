module TimerEffectTest exposing (main)

{-| Test that exercises the Platform.worker effect/scheduler mechanism.

On init, fire a 100ms timer via Process.sleep + Task.perform.
Each time it fires, update increments a counter and fires another.
After 5 firings, return Cmd.none so the program has no pending work.
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
