module ProcessYieldThrashingTest exposing (main)

{-| Two sibling fibers, each yielding via Process.sleep 0 between
log lines. Both fibers are spawned back-to-back and each runs a loop
of five iterations, so the scheduler alternates between them.

Exercises the cooperative handoff path: on each yield, the current
step returns, the run queue is processed, and the timer callback
re-enqueues the fiber. Each "A" / "B" line proves the scheduler
re-entered the fiber after a yield.
-}

-- CHECK: yield: "A 1"
-- CHECK: yield: "A 2"
-- CHECK: yield: "A 3"
-- CHECK: yield: "A 4"
-- CHECK: yield: "A 5"
-- CHECK: yield: "B 1"
-- CHECK: yield: "B 2"
-- CHECK: yield: "B 3"
-- CHECK: yield: "B 4"
-- CHECK: yield: "B 5"
-- CHECK: yield: "done"

import Platform
import Process
import Task


type Msg
    = Started
    | AllDone


type alias Model =
    {}


iters : Int
iters =
    5


yielder : String -> Int -> Task.Task Never ()
yielder label k =
    if k > iters then
        Task.succeed ()

    else
        Process.sleep 0
            |> Task.andThen
                (\_ ->
                    let
                        _ =
                            Debug.log "yield" (label ++ " " ++ String.fromInt k)
                    in
                    yielder label (k + 1)
                )


init : () -> ( Model, Cmd Msg )
init _ =
    ( {}
    , Process.spawn (yielder "A" 1)
        |> Task.andThen (\_ -> Process.spawn (yielder "B" 1))
        |> Task.perform (\_ -> Started)
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Started ->
            ( model
            , Process.sleep 200
                |> Task.perform (\_ -> AllDone)
            )

        AllDone ->
            let
                _ =
                    Debug.log "yield" "done"
            in
            ( model, Cmd.none )


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
