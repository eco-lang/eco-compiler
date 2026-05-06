module TimeEveryTest exposing (main)

{-| Test that Time.every delivers the expected number of ticks and that each
Posix value is strictly greater than the previous one. Mirrors
TimerEffectTest.elm's shape (Platform.worker, log per tick, stop after N) but
uses the Time.every subscription so it exercises the new scheduling /
rooting path through Scheduler::pendingResumes_ + TimerService and the Posix
Custom construction in timerTickEvaluator.

See plans/time-every-via-scheduler-timerservice.md.
-}

-- CHECK: TimeEveryTest: "tick 1"
-- CHECK: TimeEveryTest: "tick 2"
-- CHECK: TimeEveryTest: "tick 3"
-- CHECK: TimeEveryTest: "tick 4"
-- CHECK: TimeEveryTest: "tick 5"
-- CHECK: TimeEveryTest: "done"

import Platform
import Time


type Msg
    = Tick Time.Posix


type alias Model =
    { count : Int
    , lastMs : Int
    , done : Bool
    }


target : Int
target =
    5


intervalMs : Float
intervalMs =
    50


init : () -> ( Model, Cmd Msg )
init _ =
    ( { count = 0, lastMs = 0, done = False }
    , Cmd.none
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Tick posix ->
            let
                ms =
                    Time.posixToMillis posix

                -- Q1 regression guard: a Posix Custom decodes to a current-
                -- epoch ms (>1e12 in 2026). A raw Tag_Int read at the
                -- Custom offsets returns 0 or near-0 garbage. Strict
                -- monotonic increase plus the >0 floor catches both forms
                -- of the bug.
                strictlyIncreasing =
                    ms > model.lastMs

                positive =
                    ms > 0

                newCount =
                    model.count + 1
            in
            if not (strictlyIncreasing && positive) then
                let
                    _ =
                        Debug.log "TimeEveryTest" "non-monotonic or non-positive"
                in
                ( model, Cmd.none )

            else
                let
                    _ =
                        Debug.log "TimeEveryTest" ("tick " ++ String.fromInt newCount)

                    nextModel =
                        { count = newCount, lastMs = ms, done = newCount >= target }
                in
                if nextModel.done then
                    let
                        _ =
                            Debug.log "TimeEveryTest" "done"
                    in
                    ( nextModel, Cmd.none )

                else
                    ( nextModel, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions model =
    if model.done then
        Sub.none

    else
        Time.every intervalMs Tick


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = subscriptions
        }
