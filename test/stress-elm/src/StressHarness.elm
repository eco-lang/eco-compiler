module StressHarness exposing
    ( StressFlags
    , Model
    , Msg
    , program
    , taskProgram
    , loopWhile
    , loopWhileEvery
    , loopWhileState
    )

{-| Shared driver for CLI-parameterized stress tests.

The C++ stress-test runner populates `StressFlags` from `-n`, `-m`,
`--timeout`, `--seed`, and `-v` and delivers them as the `flags` argument
to any `Program StressFlags Model Msg`. Tests opt in to flag plumbing by
declaring that `main` shape and delegating to one of the entry points
below.

Two entry points are provided:

  - `program` — synchronous tests with a `seed` / `step` / `check` triple.
  - `taskProgram` — Task-driven tests (MVar, Spawn, multi-step Task chains).
    Tests build a `run : StressFlags -> Task Never Bool`; the harness
    invokes it once and emits `<label>: True/False` via Debug.log.

`loopWhile` and `loopWhileEvery` are helpers tests use for their inner
loop. Both honour `flags.timeoutMs`: when set, the deadline overrides the
explicit count and the loop terminates at the first iteration boundary
after the wall-clock budget is exhausted. Verdict on deadline = `True`
(the test survived the soak window). Verdict on a `False` cycle = `False`
immediately (fail-fast).
-}

import Platform
import Task exposing (Task)
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



-- ENTRY POINTS ---------------------------------------------------------------


{-| Synchronous tests with a `seed`/`step`/`check` triple. Iterates
`step` for `flags.numLoops` cycles (or until timeout, whichever comes
first) and reports `check finalState`.
-}
program :
    { label : String
    , seed : StressFlags -> state
    , step : state -> state
    , check : state -> Bool
    }
    -> Program StressFlags Model Msg
program cfg =
    let
        run flags =
            let
                initial =
                    cfg.seed flags

                cycle state =
                    Task.succeed ( cfg.step state, True )
            in
            stepLoop flags flags.numLoops initial cycle
                |> Task.map (\final -> cfg.check final)
    in
    taskProgram
        { label = cfg.label
        , run = run
        }


{-| Task-driven tests. The harness invokes `run flags` once, then emits
`<label>: True` or `<label>: False` via Debug.log. The label must match
the test's `-- CHECK:` line.
-}
taskProgram :
    { label : String
    , run : StressFlags -> Task Never Bool
    }
    -> Program StressFlags Model Msg
taskProgram cfg =
    Platform.worker
        { init = initTaskProgram cfg
        , update = updateTaskProgram cfg
        , subscriptions = \_ -> Sub.none
        }


initTaskProgram :
    { label : String, run : StressFlags -> Task Never Bool }
    -> StressFlags
    -> ( Model, Cmd Msg )
initTaskProgram cfg flags =
    ( { verdict = Nothing, label = cfg.label }
    , Task.perform GotResult (cfg.run flags)
    )


updateTaskProgram :
    { label : String, run : StressFlags -> Task Never Bool }
    -> Msg
    -> Model
    -> ( Model, Cmd Msg )
updateTaskProgram _ msg model =
    case msg of
        GotResult ok ->
            let
                _ =
                    Debug.log model.label ok
            in
            ( { model | verdict = Just ok }, Cmd.none )



-- LOOP HELPERS ---------------------------------------------------------------


{-| Run `cycle` repeatedly, fail-fast on `False`, terminate when either
the iteration budget is exhausted or the wall-clock deadline is reached.

When `flags.timeoutMs == 0` the deadline check is skipped and the loop
runs exactly `count` iterations (preserves the pre-timeout behaviour).

When `flags.timeoutMs > 0` the explicit `count` is treated as an
upper bound; the deadline is the primary termination condition. The
verdict on deadline is `True` (the test survived the soak window).

The `Int` argument to `cycle` is the iteration index, starting at 0.
-}
loopWhile :
    StressFlags
    -> Int
    -> (Int -> Task Never Bool)
    -> Task Never Bool
loopWhile flags count cycle =
    loopWhileEvery flags count 1 cycle


{-| State-threading variant of `loopWhile`. The cycle function carries
its own state (e.g. a Gen seed) across iterations. Same termination
rules: fail-fast on `False`, deadline overrides count when set, verdict
on deadline = `True`.
-}
loopWhileState :
    StressFlags
    -> Int
    -> state
    -> (Int -> state -> Task Never ( state, Bool ))
    -> Task Never Bool
loopWhileState flags count initial cycle =
    let
        budget =
            if flags.timeoutMs > 0 then
                effectivelyUnbounded

            else
                count
    in
    loopStateGo flags cycle 0 budget initial


loopStateGo :
    StressFlags
    -> (Int -> state -> Task Never ( state, Bool ))
    -> Int
    -> Int
    -> state
    -> Task Never Bool
loopStateGo flags cycle i remaining state =
    if remaining <= 0 then
        Task.succeed True

    else if flags.timeoutMs > 0 then
        Time.now
            |> Task.andThen
                (\now ->
                    let
                        elapsed =
                            Time.posixToMillis now - flags.startMs
                    in
                    if elapsed >= flags.timeoutMs then
                        Task.succeed True

                    else
                        runOneStateCycle flags cycle i remaining state
                )

    else
        runOneStateCycle flags cycle i remaining state


runOneStateCycle :
    StressFlags
    -> (Int -> state -> Task Never ( state, Bool ))
    -> Int
    -> Int
    -> state
    -> Task Never Bool
runOneStateCycle flags cycle i remaining state =
    cycle i state
        |> Task.andThen
            (\( next, ok ) ->
                if ok then
                    loopStateGo flags cycle (i + 1) (remaining - 1) next

                else
                    Task.succeed False
            )


{-| Like `loopWhile` but only samples `Time.now` every `pollEvery`
iterations. Use for tests whose single cycle is sub-millisecond and
where the time-syscall overhead would dominate. `pollEvery <= 0` is
clamped to 1.
-}
loopWhileEvery :
    StressFlags
    -> Int
    -> Int
    -> (Int -> Task Never Bool)
    -> Task Never Bool
loopWhileEvery flags count pollEvery cycle =
    let
        budget =
            if flags.timeoutMs > 0 then
                effectivelyUnbounded

            else
                count

        poll =
            if pollEvery <= 0 then
                1

            else
                pollEvery
    in
    loopGo flags poll cycle 0 budget


{-| A large but finite cap so timeout-driven runs do not loop literally
forever in the absence of any wall-clock progression (e.g. if Time.now
mis-behaves). 2^30 cycles is several hours of work even for the fastest
tests in the suite.
-}
effectivelyUnbounded : Int
effectivelyUnbounded =
    1073741824


loopGo :
    StressFlags
    -> Int
    -> (Int -> Task Never Bool)
    -> Int
    -> Int
    -> Task Never Bool
loopGo flags poll cycle i remaining =
    if remaining <= 0 then
        Task.succeed True

    else if flags.timeoutMs > 0 && modBy poll i == 0 then
        Time.now
            |> Task.andThen
                (\now ->
                    let
                        elapsed =
                            Time.posixToMillis now - flags.startMs
                    in
                    if elapsed >= flags.timeoutMs then
                        Task.succeed True

                    else
                        runOneCycle flags poll cycle i remaining
                )

    else
        runOneCycle flags poll cycle i remaining


runOneCycle :
    StressFlags
    -> Int
    -> (Int -> Task Never Bool)
    -> Int
    -> Int
    -> Task Never Bool
runOneCycle flags poll cycle i remaining =
    cycle i
        |> Task.andThen
            (\ok ->
                if ok then
                    loopGo flags poll cycle (i + 1) (remaining - 1)

                else
                    Task.succeed False
            )



-- INTERNAL: synchronous step driver used by `program` --------------------


{-| Drive a synchronous `step` for `count` iterations honouring the
deadline. Returns the final state. The Bool from `cycle` is unused for
sync tests but kept in the signature to share `loopGo`.
-}
stepLoop :
    StressFlags
    -> Int
    -> state
    -> (state -> Task Never ( state, Bool ))
    -> Task Never state
stepLoop flags count initial cycle =
    let
        budget =
            if flags.timeoutMs > 0 then
                effectivelyUnbounded

            else
                count
    in
    stepLoopGo flags cycle 0 budget initial


stepLoopGo :
    StressFlags
    -> (state -> Task Never ( state, Bool ))
    -> Int
    -> Int
    -> state
    -> Task Never state
stepLoopGo flags cycle i remaining state =
    if remaining <= 0 then
        Task.succeed state

    else if flags.timeoutMs > 0 then
        Time.now
            |> Task.andThen
                (\now ->
                    let
                        elapsed =
                            Time.posixToMillis now - flags.startMs
                    in
                    if elapsed >= flags.timeoutMs then
                        Task.succeed state

                    else
                        cycle state
                            |> Task.andThen
                                (\( next, _ ) ->
                                    stepLoopGo flags cycle (i + 1) (remaining - 1) next
                                )
                )

    else
        cycle state
            |> Task.andThen
                (\( next, _ ) ->
                    stepLoopGo flags cycle (i + 1) (remaining - 1) next
                )
