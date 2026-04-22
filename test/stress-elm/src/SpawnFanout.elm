module SpawnFanout exposing (main)

{-| Spawn 1000 fibers in a tight loop, each of which yields via
Process.sleep 0 and then performs a small fold. The parent waits
long enough for the run queue to drain, then logs "done".

Stresses rawSpawn throughput, nextProcessId_, enqueue under an
active drain, and GC of many short-lived Process heap objects.
-}

-- CHECK: fanout: "done"

import Platform
import Process
import Task


type Msg
    = Spawned
    | AllDone


type alias Model =
    {}


fiberCount : Int
fiberCount =
    1000


sumTo : Int -> Int -> Int
sumTo k acc =
    if k <= 0 then
        acc

    else
        sumTo (k - 1) (acc + k)


worker : Int -> Task.Task Never ()
worker i =
    Process.sleep 0
        |> Task.andThen
            (\_ ->
                let
                    _ =
                        sumTo (modBy 64 i + 1) 0
                in
                Task.succeed ()
            )


spawnAll : Task.Task Never ()
spawnAll =
    let
        go k =
            if k > fiberCount then
                Task.succeed ()

            else
                Process.spawn (worker k)
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
            , Process.sleep 500
                |> Task.perform (\_ -> AllDone)
            )

        AllDone ->
            let
                _ =
                    Debug.log "fanout" "done"
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
