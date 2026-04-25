module MVarHoldingHugeListAcrossGC exposing (main)

{-| Put a `m * 20` element `List Int` into an MVar, force several minor
    GCs, take it back. Stresses Cons-spine evacuation rooted from an
    MVar: every Cons cell must be copied through the scanner on every
    collection.
-}

-- CHECK: MVarHoldingHugeListAcrossGC: True

import Bytes.Decode as BD
import Bytes.Encode as BE
import Eco.MVar as MV
import StressHarness exposing (StressFlags)
import Task


heavyAlloc : Int -> Task.Task Never Int
heavyAlloc size =
    Task.succeed (List.sum (List.range 1 size))


lEnc : List Int -> BE.Encoder
lEnc _ =
    BE.unsignedInt8 0


lDec : BD.Decoder (List Int)
lDec =
    BD.succeed []


cycle : List Int -> Int -> Int -> Task.Task Never Bool
cycle original listLen size =
    MV.new
        |> Task.andThen
            (\mv ->
                MV.put lEnc mv original
                    |> Task.andThen (\_ -> heavyAlloc size)
                    |> Task.andThen (\_ -> heavyAlloc size)
                    |> Task.andThen (\_ -> heavyAlloc size)
                    |> Task.andThen (\_ -> MV.take lDec mv)
            )
        |> Task.map
            (\v ->
                List.length v == listLen && List.sum v == List.sum original
            )


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        listLen =
            flags.maxSize * 20

        original =
            List.range 1 listLen

        loopCount =
            flags.numLoops // 100
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> cycle original listLen flags.maxSize)


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "MVarHoldingHugeListAcrossGC"
        , run = run
        }
