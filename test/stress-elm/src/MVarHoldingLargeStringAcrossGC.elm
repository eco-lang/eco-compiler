module MVarHoldingLargeStringAcrossGC exposing (main)

{-| Put a multi-KB String into an MVar, force several minor GCs, take
    back and compare. Focused on `Tag_String` evacuation via the MVar
    scanner — the exact tag last-scanned in the Stage 7 crash dump.
-}

-- CHECK: MVarHoldingLargeStringAcrossGC: True

import Bytes.Decode as BD
import Bytes.Encode as BE
import Eco.MVar as MV
import StressHarness exposing (StressFlags)
import Task


heavyAlloc : Int -> Task.Task Never Int
heavyAlloc size =
    Task.succeed (List.sum (List.range 1 size))


sEnc : String -> BE.Encoder
sEnc _ =
    BE.unsignedInt8 0


sDec : BD.Decoder String
sDec =
    BD.succeed ""


cycle : String -> Int -> Task.Task Never Bool
cycle original size =
    MV.new
        |> Task.andThen
            (\mv ->
                MV.put sEnc mv original
                    |> Task.andThen (\_ -> heavyAlloc size)
                    |> Task.andThen (\_ -> heavyAlloc size)
                    |> Task.andThen (\_ -> heavyAlloc size)
                    |> Task.andThen (\_ -> MV.take sDec mv)
            )
        |> Task.map (\v -> v == original)


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        original =
            String.repeat (flags.maxSize // 2) "The quick brown fox jumps over the lazy dog. "

        loopCount =
            flags.numLoops // 100
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> cycle original flags.maxSize)


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "MVarHoldingLargeStringAcrossGC"
        , run = run
        }
