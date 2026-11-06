module TimeEveryTest exposing (main)

{-| `Time.every` delivers repeated ticks to a `Platform.worker`, each carrying a time later than the one before.

The worker subscribes to `Time.every 50` and logs `"tick n"` for each tick
whose time in milliseconds is positive and strictly greater than the previous
tick's. After the fifth such tick it logs `"done"` and drops the subscription.
A tick that fails the check is logged as `"non-monotonic or non-positive"` and
not counted.

-}

-- CHECK: TimeEveryTest: "tick 1"
-- CHECK: TimeEveryTest: "tick 2"
-- CHECK: TimeEveryTest: "tick 3"
-- CHECK: TimeEveryTest: "tick 4"
-- CHECK: TimeEveryTest: "tick 5"
-- CHECK: TimeEveryTest: "done"

import Platform
import Time


{-| A tick from `Time.every`, carrying the time it fired.
-}
type Msg
    = Tick Time.Posix


{-| How many valid ticks have arrived, the time of the last one in milliseconds
(0 before the first), and whether `target` has been reached.
-}
type alias Model =
    { count : Int
    , lastMs : Int
    , done : Bool
    }


{-| The number of valid ticks after which the worker stops.
-}
target : Int
target =
    5


{-| The interval passed to `Time.every`, in milliseconds.
-}
intervalMs : Float
intervalMs =
    50


{-| Starts with no ticks counted and no command.
-}
init : () -> ( Model, Cmd Msg )
init _ =
    ( { count = 0, lastMs = 0, done = False }
    , Cmd.none
    )


{-| Checks a tick against the previous one, logs it, and counts it if it is valid.
-}
update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Tick posix ->
            let
                ms =
                    Time.posixToMillis posix

                -- The current time is far above zero, so a tick whose time
                -- reads as zero or as no later than the last one is wrong.
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


{-| Subscribes to `Time.every` until `target` valid ticks have arrived, then to nothing.
-}
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
