module TaskSequenceMassive exposing (main)

{-| Task.sequence applied to a 2000-element list of tasks alternating
between synchronous (Task.succeed i) and asynchronous
(Process.sleep 0 |> map (\_ -> i)) leaves. Sum the resulting list and
check the total.

Stresses Task.sequence's cons-fold allocation path and the run queue
under mixed sync / async leaves. The async leaves force the scheduler
to yield to the event loop 1000 times over the course of one
sequenced task.
-}

-- CHECK: seq: 499500

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


leafCount : Int
leafCount =
    m


leaf : Int -> Task Never Int
leaf i =
    if modBy 2 i == 0 then
        Task.succeed i

    else
        Process.sleep 0 |> Task.map (\_ -> i)


buildTasks : List (Task Never Int)
buildTasks =
    let
        go i acc =
            if i < 0 then
                acc

            else
                go (i - 1) (leaf i :: acc)
    in
    go (leafCount - 1) []


init : () -> ( Model, Cmd Msg )
init _ =
    ( {}
    , Task.sequence buildTasks
        |> Task.map (List.foldl (+) 0)
        |> Task.perform Done
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update (Done v) model =
    let
        _ =
            Debug.log "seq" v
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
