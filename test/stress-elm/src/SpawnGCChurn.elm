module SpawnGCChurn exposing (main)

{-| Spawn 300 fibers that each allocate and discard a List of 200
integers across several Process.sleep 0 yields, while the parent
fiber simultaneously folds over an 8000-element list and discards it.
The combination forces GC cycles while Process heap objects are live
on the run queue.

Validates that encoded RootedProc entries keep fibers rooted across
collections and that per-fiber stack frames are walked correctly
during marking.
-}

-- CHECK: gcChurn: "done"

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
    m // 3


allocSize : Int
allocSize =
    m // 5


yieldCount : Int
yieldCount =
    4


parentFoldSize : Int
parentFoldSize =
    m * 8


buildList : Int -> List Int
buildList count =
    let
        go k acc =
            if k <= 0 then
                acc

            else
                go (k - 1) (k :: acc)
    in
    go count []


worker : Task.Task Never ()
worker =
    let
        loop y =
            if y <= 0 then
                Task.succeed ()

            else
                Process.sleep 0
                    |> Task.andThen
                        (\_ ->
                            let
                                xs =
                                    buildList allocSize

                                _ =
                                    List.foldl (+) 0 xs
                            in
                            loop (y - 1)
                        )
    in
    loop yieldCount


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


parentChurn : Task.Task Never ()
parentChurn =
    Process.sleep 0
        |> Task.map
            (\_ ->
                let
                    xs =
                        buildList parentFoldSize

                    _ =
                        List.foldl (+) 0 xs
                in
                ()
            )


init : () -> ( Model, Cmd Msg )
init _ =
    ( {}
    , spawnAll
        |> Task.andThen (\_ -> parentChurn)
        |> Task.perform (\_ -> Spawned)
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
                    Debug.log "gcChurn" "done"
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
