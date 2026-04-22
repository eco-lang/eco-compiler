module ProcessSpawnRecursiveTest exposing (main)

{-| A fiber that spawns a child, which spawns a grandchild, recursing
to depth 5. Each level logs its depth; the deepest level logs "bottom".
After all levels have had time to run, the main fiber logs "done".

Exercises recursive enqueue during an active drain and root
registration of nested Process objects.
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
