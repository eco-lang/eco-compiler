module ProcessSpawnRecursiveTest exposing (main)

{-| A process spawned with `Process.spawn` can itself spawn a process, nested
five deep, and every level runs.

Level `k` sleeps 10 ms, logs `spawned k`, and then spawns level `k + 1`; level
5 logs `bottom` instead of spawning. `init` spawns level 1, and the program
logs `done` after a 300 ms sleep, by which time every level has run.

-}

-- CHECK: recurse: "spawned 1"
-- CHECK: recurse: "spawned 2"
-- CHECK: recurse: "spawned 3"
-- CHECK: recurse: "spawned 4"
-- CHECK: recurse: "spawned 5"
-- CHECK: recurse: "bottom"
-- CHECK: recurse: "done"

import Platform
import Process
import Task


type Msg
    = Started
    | AllDone


type alias Model =
    {}


depth : Int
depth =
    5


recur : Int -> Task.Task Never ()
recur k =
    Process.sleep 10
        |> Task.andThen
            (\_ ->
                let
                    _ =
                        Debug.log "recurse" ("spawned " ++ String.fromInt k)
                in
                if k >= depth then
                    let
                        _ =
                            Debug.log "recurse" "bottom"
                    in
                    Task.succeed ()

                else
                    Process.spawn (recur (k + 1))
                        |> Task.map (\_ -> ())
            )


init : () -> ( Model, Cmd Msg )
init _ =
    ( {}
    , Process.spawn (recur 1)
        |> Task.perform (\_ -> Started)
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Started ->
            ( model
            , Process.sleep 300
                |> Task.perform (\_ -> AllDone)
            )

        AllDone ->
            let
                _ =
                    Debug.log "recurse" "done"
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
