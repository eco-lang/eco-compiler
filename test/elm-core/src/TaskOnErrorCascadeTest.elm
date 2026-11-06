module TaskOnErrorCascadeTest exposing (main)

{-| `Task.onError` recovers a failed `Task.andThen` chain, skipping the steps
between the failure and the handler, and the recovered task can be chained
further.

`segment step` adds 1 to `step`, then fails with `"boom"`, so the following
`andThen` that would add 100 never runs, and its `onError` handler logs
`recovered <step>` and succeeds with `step * 10`. `chain` runs segments 1, 2 and
3 in order and sums their results, so the worker logs the three recoveries in
order and then `final: 60`.

Among what is not tested: a handler that fails again, and a failure that reaches
`Task.attempt` unrecovered.

-}

-- CHECK: onerr: "recovered 1"
-- CHECK: onerr: "recovered 2"
-- CHECK: onerr: "recovered 3"
-- CHECK: onerr: "final: 60"

import Platform
import Task exposing (Task)


type Msg
    = Done Int


type alias Model =
    {}


segment : Int -> Task String Int
segment step =
    Task.succeed step
        |> Task.andThen (\x -> Task.succeed (x + 1))
        |> Task.andThen (\_ -> Task.fail "boom")
        |> Task.andThen (\x -> Task.succeed (x + 100))
        |> Task.onError
            (\_ ->
                let
                    _ =
                        Debug.log "onerr" ("recovered " ++ String.fromInt step)
                in
                Task.succeed (step * 10)
            )


chain : Task String Int
chain =
    segment 1
        |> Task.andThen (\a -> segment 2 |> Task.map (\b -> a + b))
        |> Task.andThen (\ab -> segment 3 |> Task.map (\c -> ab + c))


handleResult : Result String Int -> Msg
handleResult r =
    case r of
        Ok v ->
            Done v

        Err _ ->
            Done -1


init : () -> ( Model, Cmd Msg )
init _ =
    ( {}
    , Task.attempt handleResult chain
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update (Done v) model =
    let
        _ =
            Debug.log "onerr" ("final: " ++ String.fromInt v)
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
