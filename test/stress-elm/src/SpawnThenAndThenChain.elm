module SpawnThenAndThenChain exposing (main)

{-| Spawn 200 fibers, each running a 50-step Process.sleep 0 + andThen
chain. Combines fan-out breadth with chain depth: 10 000 scheduler
resumption events in total.

Stresses the run queue under continuous re-enqueue (each fiber
yields 50 times) and pap-extend allocation while many fibers are
simultaneously waiting on timers.
-}

-- CHECK: spawnChain: "done"

import Platform
import Process
import Task


type Msg
    = Spawned
    | AllDone


type alias Model =
    {}


n : Int
n =
    1000


m : Int
m =
    1000


loopCount : Int
loopCount =
    n // 1000


fiberCount : Int
fiberCount =
    m // 5


chainDepth : Int
chainDepth =
    m // 20


innerChain : Int -> Int -> Task.Task Never Int
innerChain i acc =
    if i <= 0 then
        Task.succeed acc

    else
        Process.sleep 0
            |> Task.andThen (\_ -> innerChain (i - 1) (acc + 1))


worker : Task.Task Never ()
worker =
    innerChain chainDepth 0
        |> Task.map (\_ -> ())


spawnAll : Task.Task Never ()
spawnAll =
    let
        go k =
            if k > fiberCount then
                Task.succeed ()

            else
                Process.spawn worker
                    |> Task.andThen (\_ -> go (k + 1))
    in
    go 1


init : () -> ( Model, Cmd Msg )
init _ =
    ( {}
    , spawnAll |> Task.perform (\_ -> Spawned)
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Spawned ->
            ( model
            , Process.sleep 1000
                |> Task.perform (\_ -> AllDone)
            )

        AllDone ->
            let
                _ =
                    Debug.log "spawnChain" "done"
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
