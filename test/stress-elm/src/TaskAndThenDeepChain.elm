module TaskAndThenDeepChain exposing (main)

{-| Build a 2000-deep Task.andThen chain counting up from 0, with a
Process.sleep 0 yield every 32 steps so the scheduler actually
re-enters the fiber. Checks the final accumulated value.

Stresses construction of TASK_AND_THEN heap nodes (the chain allocates
2000 of them before scheduling), the stack-frame list built up in
stepProcess during unwinding, and the interaction between synchronous
andThen folding and periodic BINDING yields.
-}

-- CHECK: chain: 1000

import Platform
import Process
import Task exposing (Task)


type Msg
    = Done Int


type alias Model =
    {}


n : Int
n =
    1000


m : Int
m =
    1000


chainDepth : Int
chainDepth =
    m


yieldEvery : Int
yieldEvery =
    32


step : Int -> Int -> Task Never Int
step i x =
    if modBy yieldEvery i == 0 then
        Process.sleep 0 |> Task.map (\_ -> x + 1)

    else
        Task.succeed (x + 1)


buildChain : Task Never Int
buildChain =
    let
        go i task =
            if i > chainDepth then
                task

            else
                go (i + 1) (task |> Task.andThen (step i))
    in
    go 1 (Task.succeed 0)


init : () -> ( Model, Cmd Msg )
init _ =
    ( {}
    , buildChain |> Task.perform Done
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update (Done v) model =
    let
        _ =
            Debug.log "chain" v
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
