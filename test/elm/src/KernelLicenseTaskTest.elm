module KernelLicenseTaskTest exposing (main)

{-| LSS_022 — the `Scheduler` licences (2026-08-25).

`Scheduler.succeed/fail/andThen/onError` sat on the REJECTED list under the
old "nullary-constructor carrier" predicate: `type Task err ok = Task`
declares no fields, so its parameters LOOK phantom while the C++ fills them
with payload. That predicate over-refused. Passing a value THROUGH an opaque
carrier is not retention in any sense the set analysis cares about — the
scheduler hands back exactly what was stored, and `a` is the SAME type
variable in `a -> Task x a`, so ordinary unification carries the set across.
It is `JsArray.singleton : a -> JsArray a` with a carrier that happens not to
name its field.

The risk a licence takes on is the FALSE SINGLETON: if a licensed position
carried a narrower set than the values actually inhabiting it, a downstream
consumer would stamp a direct call to the wrong closure and one lambda's code
would run in another's place. So every CHECK below is chosen so that a
collapse prints a DIFFERENT NUMBER rather than crashing — the `b: 11`
discipline of `KernelLicenseTest.elm`.

  - `a`/`b` — a FUNCTION stored in a Task's `a` and taken back out through
    `andThen`. This is the position the licence newly opens: poisoned, the
    callback's parameter read ⊤; licensed, it carries the caller's lambda.
    Two distinct functions through the SAME `succeed`/`andThen` pair, so a
    collapse swaps `+1` for `*10` — `410`/`42` instead of `42`/`410`.
  - `c` — both inhabitants reaching ONE shared `andThen` call site through a
    list, so the arrow carries a genuine 2-member set rather than two
    separately-keyed singletons. A singleton stamp prints `[42,42]` or
    `[410,410]` instead of `[42,410]`.
  - `d` — `onError`'s SUCCESS path: the inner task succeeds, the handler
    never runs, and the inner `a` IS the result's `a`. That edge is a shared
    type variable in `Task x a -> Task y a` and is exactly what the licence
    asserts.
  - `e` — `onError`'s FAILURE path: the handler is applied to the error and
    its result becomes the task. A distinct constant from `d`, so the two
    paths cannot be confused for one another.

Runs on eco's native Task scheduler via `Platform.worker`, so these are real
fulfilments — the licences are about what the scheduler actually does with a
stored callback, and a simulated Task would not exercise them.

The observations run INSIDE the `andThen` callbacks rather than in `update`,
which also exercises the licensed `andThen` edge directly. The
value-carrying `update` path is covered separately by
`TaskPerformValueTest` / `TaskAttemptErrorTest` — the fixtures that found
and now pin the `initWorker` unboxed-model defect this fixture originally
tripped over.

-}

-- CHECK: a: 42
-- CHECK: b: 410
-- CHECK: c: [42, 410]
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


{-| Store a FUNCTION in the Task's `a`, take it back out through `andThen`,
and apply it. If the licence were unsound, `g` at the callback would not be
the `f` that went into `succeed`.
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


{-| Both inhabitants reach ONE `andThen` call site.
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


{-| `onError` pass-through: inner task SUCCEEDS, handler never runs.
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


{-| `onError` handler edge: inner task FAILS, handler's result becomes it.
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
