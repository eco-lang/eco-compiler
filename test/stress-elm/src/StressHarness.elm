module StressHarness exposing
    ( StressFlags
    , Model
    , Msg
    , program
    )

{-| Shared driver for CLI-parameterized stress tests.

Tests opt in by declaring `main : Program StressFlags (Model state) Msg`
and delegating to `program` with their own `seed`, `step`, and `check`
functions. The stress-test binary populates StressFlags from `-n`, `-m`,
`--timeout`, `--seed`, and `-v` before launching the program.

The loop runs as a single `Task` built in `init`, mirroring the pattern
used by existing stress tests (e.g. ModifyMVarCounterStress). This
avoids the per-iteration update cycle overhead that an outer Tick/Tock
driver would incur. Wall-clock timeout is checked once per iteration
via `Time.now` inside the Task chain.
-}

import Platform
import Task
import Time


type alias StressFlags =
    { maxSize : Int
    , numLoops : Int
    , seed : Int
    , startMs : Int
    , timeoutMs : Int
    , verbose : Bool
    }


type Msg
    = GotResult Bool


type alias Model =
    { verdict : Maybe Bool
    , label : String
    }


program :
    { label : String
    , seed : StressFlags -> state
    , step : state -> state
    , check : state -> Bool
    }
    -> Program StressFlags Model Msg
program cfg =
    Platform.worker
        { init = initWith cfg
        , update = updateWith cfg
        , subscriptions = \_ -> Sub.none
        }


initWith :
    { label : String
    , seed : StressFlags -> state
    , step : state -> state
    , check : state -> Bool
    }
    -> StressFlags
    -> ( Model, Cmd Msg )
initWith cfg flags =
    let
        initial =
            cfg.seed flags

        task =
            runLoop cfg flags flags.numLoops initial
    in
    ( { verdict = Nothing, label = cfg.label }
    , Task.perform GotResult task
    )


{-| Run the inner loop as a Task. When timeoutMs is 0, the hot path is
a tight Task.andThen chain with no time-sampling overhead. When
timeoutMs > 0, each iteration consults `Time.now` and bails early.
-}
runLoop :
    { label : String
    , seed : StressFlags -> state
    , step : state -> state
    , check : state -> Bool
    }
    -> StressFlags
    -> Int
    -> state
    -> Task.Task Never Bool
runLoop cfg flags remaining state =
    if remaining <= 0 then
        Task.succeed (cfg.check state)

    else if flags.timeoutMs > 0 then
        Time.now
            |> Task.andThen
                (\t ->
                    let
                        elapsed =
                            Time.posixToMillis t - flags.startMs
                    in
                    if elapsed > flags.timeoutMs then
                        Task.succeed False

                    else
                        runLoop cfg flags (remaining - 1) (cfg.step state)
                )

    else
        runLoop cfg flags (remaining - 1) (cfg.step state)


updateWith :
    { label : String
    , seed : StressFlags -> state
    , step : state -> state
    , check : state -> Bool
    }
    -> Msg
    -> Model
    -> ( Model, Cmd Msg )
updateWith _ msg model =
    case msg of
        GotResult ok ->
            let
                _ =
                    Debug.log model.label ok
            in
            ( { model | verdict = Just ok }, Cmd.none )
