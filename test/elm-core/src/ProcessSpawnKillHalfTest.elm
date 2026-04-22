module ProcessSpawnKillHalfTest exposing (main)

{-| Spawn 10 fibers, each of which sleeps briefly and then logs a line.
Immediately after spawning, kill every even-indexed fiber. Only the
odd-indexed fibers (1, 3, 5, 7, 9) should log. After waiting long enough
for any survivors to fire, log "done".

Exercises Scheduler::killTask, the BINDING.__kill cancel path, and
verifies that a killed fiber does not execute the continuation after
its sleep would have fired.
-}

-- CHECK: spawnKill: "fired 1"
-- CHECK: spawnKill: "fired 3"
-- CHECK: spawnKill: "fired 5"
-- CHECK: spawnKill: "fired 7"
-- CHECK: spawnKill: "fired 9"
-- CHECK: spawnKill: "done"

import Platform
import Process
import Task


type Msg
    = Spawned (List Process.Id)
    | AllDone


type alias Model =
    { ids : List Process.Id }


fiberCount : Int
fiberCount =
    10


worker : Int -> Task.Task Never ()
worker i =
    Process.sleep (toFloat (i * 10))
        |> Task.andThen
            (\_ ->
                let
                    _ =
                        Debug.log "spawnKill" ("fired " ++ String.fromInt i)
                in
                Task.succeed ()
            )


spawnAll : Task.Task Never (List Process.Id)
spawnAll =
    let
        go k acc =
            if k > fiberCount then
                Task.succeed (List.reverse acc)

            else
                Process.spawn (worker k)
                    |> Task.andThen (\id -> go (k + 1) (id :: acc))
    in
    go 1 []


killEven : List Process.Id -> Task.Task Never ()
killEven ids =
    let
        go k remaining =
            case remaining of
                [] ->
                    Task.succeed ()

                id :: rest ->
                    if modBy 2 k == 0 then
                        Process.kill id
                            |> Task.andThen (\_ -> go (k + 1) rest)

                    else
                        go (k + 1) rest
    in
    go 1 ids


init : () -> ( Model, Cmd Msg )
init _ =
    ( { ids = [] }
    , spawnAll
        |> Task.andThen (\ids -> killEven ids |> Task.map (\_ -> ids))
        |> Task.perform Spawned
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Spawned ids ->
            ( { model | ids = ids }
            , Process.sleep 300
                |> Task.perform (\_ -> AllDone)
            )

        AllDone ->
            let
                _ =
                    Debug.log "spawnKill" "done"
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
