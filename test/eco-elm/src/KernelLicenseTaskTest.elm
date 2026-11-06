module KernelLicenseTaskTest exposing (main)

{-| Checks that values passed through `Task.succeed`, `Task.andThen` and `Task.onError` come out unchanged, including functions.

The program is a `Platform.worker` whose `init` performs five tasks. Each task
prints its observation from inside an `andThen` callback:

  - `a` and `b` put a function in `Task.succeed`, take it back out with
    `andThen`, and apply it to 41. The two functions differ (`+ 1` and
    `* 10`), so mixing them up would print 410 and 42 instead of 42 and 410.
  - `c` sends both functions through the same `succeed`/`andThen` code in
    `List.map`, collects the results with `Task.sequence`, and prints
    `[42,410]`.
  - `d` applies `onError` to a task that succeeds with 7; the handler does not
    run and 7 comes through.
  - `e` applies `onError` to a task that fails; the handler's `succeed 99`
    becomes the result.

## eco

Exercises the LSS_022 kernel licenses (design_docs/invariants.csv;
plans/kernel-parametricity-license.md) for `Scheduler.succeed`, `fail`,
`andThen` and `onError`. These were once refused because `Task` declares no
fields, so its parameters looked phantom, but the scheduler hands back exactly
the stored value, so ordinary unification can carry lambda sets through.

The risk of a license is a false singleton: a downstream call stamped as a
direct call to the wrong closure. Each CHECK is chosen so such a collapse
prints a different number rather than crashing: `a`/`b` swap 42 and 410; `c`
gives one `andThen` call site a genuine two-member set, and a singleton stamp
would print `[42,42]` or `[410,410]`; `d` and `e` cover the success and failure
edges of `onError`.

It runs on eco's native Task scheduler via `Platform.worker`, so the tasks
really run. The observations are made inside `andThen` callbacks; the value
carrying `update` path is covered by test/elm/src/TaskPerformValueTest.elm and
test/elm/src/TaskAttemptErrorTest.elm.

-}

-- CHECK: a: 42
-- CHECK: b: 410
-- CHECK: c: [42,410]
-- CHECK: d: 7
-- CHECK: e: 99

import Platform
import Task exposing (Task)


type Msg
    = Done


type alias Model =
    Int


incr : Int -> Int
incr x =
    x + 1


tenfold : Int -> Int
tenfold x =
    x * 10


{-| Builds a task that succeeds with `f`, takes it back out with `andThen`, and
logs `f n` under `label`.
-}
runWith : String -> (Int -> Int) -> Int -> Task Never ()
runWith label f n =
    Task.succeed f
        |> Task.andThen
            (\g ->
                let
                    _ =
                        Debug.log label (g n)
                in
                Task.succeed ()
            )


{-| Builds a task that applies each of `fs` to `n` through the same
`succeed`/`andThen` code and logs the list of results under `c`.
-}
runAll : List (Int -> Int) -> Int -> Task Never (List Int)
runAll fs n =
    Task.sequence (List.map (\f -> Task.succeed f |> Task.andThen (\g -> Task.succeed (g n))) fs)
        |> Task.andThen
            (\xs ->
                let
                    _ =
                        Debug.log "c" xs
                in
                Task.succeed xs
            )


{-| A task that succeeds with 7 before `onError`, so its handler does not run;
the 7 is logged under `d`.
-}
passThrough : Task Never Int
passThrough =
    Task.succeed 7
        |> Task.onError (\_ -> Task.succeed 0)
        |> Task.andThen
            (\v ->
                let
                    _ =
                        Debug.log "d" v
                in
                Task.succeed v
            )


{-| A task that fails before `onError`, so the handler's `succeed 99` becomes
its result, which is logged under `e`.
-}
recovered : Task Never Int
recovered =
    Task.fail "boom"
        |> Task.onError (\_ -> Task.succeed 99)
        |> Task.andThen
            (\v ->
                let
                    _ =
                        Debug.log "e" v
                in
                Task.succeed v
            )


init : () -> ( Model, Cmd Msg )
init _ =
    ( 0
    , Cmd.batch
        [ Task.perform (\_ -> Done) (runWith "a" incr 41)
        , Task.perform (\_ -> Done) (runWith "b" tenfold 41)
        , Task.perform (\_ -> Done) (runAll [ incr, tenfold ] 41)
        , Task.perform (\_ -> Done) passThrough
        , Task.perform (\_ -> Done) recovered
        ]
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Done ->
            ( model + 1, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
