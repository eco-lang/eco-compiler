module TaskPerformValueTest exposing (main)

{-| `Task.perform` must deliver the task's VALUE to `update`.

That is the whole purpose of `perform`, and until 2026-08-25 nothing covered
it: `TimerEffectTest` uses a CONSTANT tagger (`\_ -> TimerFired`), so the
fulfilled value is discarded and never has to survive the trip through
`spawnCmd` → `Platform.sendToApp` → the process mailbox → `update`.

The chain under test (elm/core `Task.elm`):

    perform toMessage task = command (Perform (map toMessage task))
    spawnCmd router (Perform task) =
        Scheduler.spawn (task |> andThen (Platform.sendToApp router))

Both a payload-carrying Msg and a nullary one are exercised, so a failure
localises immediately: if `a` passes but `b` crashes, the defect is in
carrying a value, not in `perform` itself.

-}

-- CHECK: a: 42
-- CHECK: b: "nullary ok"
-- CHECK: c: -7
-- CHECK: d: "hello"

import Platform
import Task


type Msg
    = GotInt Int
    | GotNullary
    | GotNeg Int
    | GotStr String


init : () -> ( Int, Cmd Msg )
init _ =
    ( 0
    , Cmd.batch
        [ Task.perform GotInt (Task.succeed 42)
        , Task.perform (\_ -> GotNullary) (Task.succeed 1)
        , Task.perform GotNeg (Task.succeed -7)
        , Task.perform GotStr (Task.succeed "hello")
        ]
    )


update : Msg -> Int -> ( Int, Cmd Msg )
update msg model =
    case msg of
        GotInt v ->
            let
                _ =
                    Debug.log "a" v
            in
            ( model + 1, Cmd.none )

        GotNullary ->
            let
                _ =
                    Debug.log "b" "nullary ok"
            in
            ( model + 1, Cmd.none )

        GotNeg v ->
            let
                _ =
                    Debug.log "c" v
            in
            ( model + 1, Cmd.none )

        GotStr s ->
            let
                _ =
                    Debug.log "d" s
            in
            ( model + 1, Cmd.none )


main : Program () Int Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
