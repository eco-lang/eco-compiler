module MVarHoldingMVarStress exposing (main)

{-| Put an inner MVar (itself holding an Int) into an outer MVar,
    force multiple minor GCs, retrieve the inner across the collection,
    then use the inner's value. Verifies MVars-as-values keep their id
    identity across scanner roundtrips.
-}

-- CHECK: MVarHoldingMVarStress: True

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


mvarEnc : MV.MVar Int -> BE.Encoder
mvarEnc _ =
    BE.unsignedInt8 0


mvarDec : BD.Decoder (MV.MVar Int)
mvarDec =
    BD.succeed (MV.MVar 0)


heavyAlloc : Int -> Task.Task Never Int
heavyAlloc size =
    Task.succeed (List.sum (List.range 1 size))


cycle : Int -> Task.Task Never Bool
cycle size =
    MV.new
        |> Task.andThen
            (\inner ->
                MV.put intEnc inner 424242
                    |> Task.andThen (\_ -> MV.new)
                    |> Task.andThen
                        (\outer ->
                            MV.put mvarEnc outer inner
                                |> Task.andThen (\_ -> heavyAlloc size)
                                |> Task.andThen (\_ -> heavyAlloc size)
                                |> Task.andThen (\_ -> heavyAlloc size)
                                |> Task.andThen (\_ -> MV.take mvarDec outer)
                        )
                    |> Task.andThen (MV.take intDec)
            )
        |> Task.map (\v -> v == 424242)


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
        { label = "MVarHoldingMVarStress"
        , run = run
        }
