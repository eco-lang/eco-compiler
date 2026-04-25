module MVarBlockingReadAwaitsPutStress exposing (main)

{-| Exercise a genuinely blocking `MVar.read`:

    1. Create an empty data MVar and an empty result MVar.
    2. Spawn a reader fiber that calls `MV.read` on the
       empty data MVar. The reader MUST block here because
       the MVar is empty at the point it runs.
    3. The parent sleeps 100 ms — long enough for the reader
       fiber to be scheduled, reach the read, and park.
    4. The parent puts the expected value into the data MVar.
    5. The reader wakes, copies the value into the result MVar.
    6. The parent takes the result MVar and compares.

    Without working blocking reads the reader's `MV.read`
    hits an empty MVar and aborts.
-}

-- CHECK: MVarBlockingReadAwaitsPutStress: True

import Bytes.Decode as BD
import Bytes.Encode as BE
import Eco.MVar as MV
import Process
import StressHarness exposing (StressFlags)
import Task


{-| The kernel MVar store ignores these encoders/decoders —
    values round-trip via the hidden HPointer slot. Stubs suffice.
-}
intEnc : Int -> BE.Encoder
intEnc _ =
    BE.unsignedInt8 0


intDec : BD.Decoder Int
intDec =
    BD.succeed 0


reader : MV.MVar Int -> MV.MVar Int -> Task.Task Never ()
reader dataMVar resultMVar =
    MV.read intDec dataMVar
        |> Task.andThen (\v -> MV.put intEnc resultMVar v)


cycle : Int -> Task.Task Never Bool
cycle expected =
    MV.new
        |> Task.andThen
            (\dataMVar ->
                MV.new
                    |> Task.andThen
                        (\resultMVar ->
                            Process.spawn (reader dataMVar resultMVar)
                                |> Task.andThen (\_ -> Process.sleep 100)
                                |> Task.andThen (\_ -> MV.put intEnc dataMVar expected)
                                |> Task.andThen (\_ -> MV.take intDec resultMVar)
                        )
            )
        |> Task.map (\v -> v == expected)


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        loopCount =
            flags.numLoops // 100

        expected =
            flags.maxSize * 4 + 242
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> cycle expected)


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "MVarBlockingReadAwaitsPutStress"
        , run = run
        }
