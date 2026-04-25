module ModifyMVarCounterStress exposing (main)

{-| Mimic the `modifyMVar` pattern from the compiler's `Utils.Main`:
    take the current value, produce a new one, put it back. Runs a
    counter loop N k times with per-iteration allocation pressure to
    force minor GCs during the take/put sequence.

    End state: counter == n.
-}

-- CHECK: ModifyMVarCounterStress: True

import Bytes.Decode as BD
import Bytes.Encode as BE
import Eco.MVar as MV
import StressHarness exposing (StressFlags)
import Task


intEnc : Int -> BE.Encoder
intEnc _ =
    BE.unsignedInt8 0


intDec : BD.Decoder Int
intDec =
    BD.succeed 0


smallAlloc : Int -> Task.Task Never Int
smallAlloc size =
    Task.succeed (List.sum (List.range 1 size))


modifyInc : MV.MVar Int -> Task.Task Never ()
modifyInc mvar =
    MV.take intDec mvar
        |> Task.andThen (\v -> MV.put intEnc mvar (v + 1))


loop : Int -> Int -> MV.MVar Int -> Int -> Task.Task Never ()
loop count size mvar remaining =
    if remaining <= 0 then
        Task.succeed ()

    else
        modifyInc mvar
            |> Task.andThen (\_ -> smallAlloc size)
            |> Task.andThen (\_ -> loop count size mvar (remaining - 1))


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        count =
            flags.numLoops

        size =
            flags.maxSize
    in
    MV.new
        |> Task.andThen
            (\mvar ->
                MV.put intEnc mvar 0
                    |> Task.andThen (\_ -> loop count size mvar count)
                    |> Task.andThen (\_ -> MV.take intDec mvar)
            )
        |> Task.map (\v -> v == count)


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "ModifyMVarCounterStress"
        , run = run
        }
