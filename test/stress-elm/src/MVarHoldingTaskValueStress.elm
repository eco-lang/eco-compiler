module MVarHoldingTaskValueStress exposing (main)

{-| Put a `Task Never Int` value (a heap object with internal pointer
    chains) into an MVar, force multiple minor GCs, take the task back,
    then execute it. Stresses Task-tag evacuation via the MVar
    scanner — Tasks are frequently in flight during compiler execution.
-}

-- CHECK: MVarHoldingTaskValueStress: True

import Bytes.Decode as BD
import Bytes.Encode as BE
import Eco.IO.Error exposing (IOError)
import Eco.MVar as MV
import StressHarness exposing (StressFlags)
import Task


taskEnc : Task.Task Never Int -> BE.Encoder
taskEnc _ =
    BE.unsignedInt8 0


taskDec : BD.Decoder (Task.Task Never Int)
taskDec =
    BD.succeed (Task.succeed 0)


heavyAlloc : Int -> Task.Task IOError Int
heavyAlloc size =
    Task.succeed (List.sum (List.range 1 size))


cycle : Int -> Task.Task Never Bool
cycle size =
    let
        inner : Task.Task Never Int
        inner =
            Task.succeed 777
                |> Task.andThen (\v -> Task.succeed (v + 23))
    in
    MV.new
        |> Task.andThen
            (\mv ->
                MV.put taskEnc mv inner
                    |> Task.andThen (\_ -> heavyAlloc size)
                    |> Task.andThen (\_ -> heavyAlloc size)
                    |> Task.andThen (\_ -> heavyAlloc size)
                    |> Task.andThen (\_ -> MV.take taskDec mv)
            )
        |> Task.andThen (\t -> Task.mapError never t)
        |> Task.map (\v -> v == 800)
        |> Task.onError (\_ -> Task.succeed False)


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        loopCount =
            flags.numLoops // 100
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> cycle flags.maxSize)


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "MVarHoldingTaskValueStress"
        , run = run
        }
