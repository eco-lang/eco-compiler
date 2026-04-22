module TaskOnErrorCascadeTest exposing (main)

{-| A chain of andThen calls that fails partway, recovers via onError,
and then continues into another segment. Running three such segments
sequentially and summing their results exercises the TASK_FAIL /
TASK_ON_ERROR stack-unwinding path in stepProcess: each fail must walk
the stack to the nearest ON_ERROR, discard intervening AND_THEN
frames, and resume with a Task.succeed.

segment step =
    succeed step
        |> andThen (\x -> succeed (x + 1))     -- runs
        |> andThen (\_ -> fail "boom")         -- fails
        |> andThen (\x -> succeed (x + 100))   -- skipped
        |> onError (\_ -> succeed (step * 10)) -- recovers

so segment 1 -> 10, segment 2 -> 20, segment 3 -> 30, total 60.
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
