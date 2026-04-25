module SpawnGCChurn exposing (main)

{-| Spawn fibers that each allocate and discard a List across several
Process.sleep 0 yields, while the parent fiber simultaneously folds
over a larger list and discards it. The combination forces GC cycles
while Process heap objects are live on the run queue.

Validates that encoded RootedProc entries keep fibers rooted across
collections and that per-fiber stack frames are walked correctly
during marking.
-}

-- CHECK: SpawnGCChurn: True

import Process
import StressHarness exposing (StressFlags)
import Task


yieldCount : Int
yieldCount =
    4


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


worker : Int -> Task.Task Never ()
worker allocSize =
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


spawnAll : Int -> Int -> Task.Task Never ()
spawnAll fiberCount allocSize =
    let
        go k =
            if k > fiberCount then
                Task.succeed ()

            else
                Process.spawn (worker allocSize)
                    |> Task.andThen (\_ -> go (k + 1))
    in
    go 1


parentChurn : Int -> Task.Task Never ()
parentChurn parentFoldSize =
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


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        fiberCount =
            flags.maxSize // 3

        allocSize =
            flags.maxSize // 5

        parentFoldSize =
            flags.maxSize * 8
    in
    spawnAll fiberCount allocSize
        |> Task.andThen (\_ -> parentChurn parentFoldSize)
        |> Task.andThen (\_ -> Process.sleep 1000)
        |> Task.map (\_ -> True)


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "SpawnGCChurn"
        , run = run
        }
