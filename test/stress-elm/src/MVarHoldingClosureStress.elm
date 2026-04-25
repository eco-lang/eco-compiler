module MVarHoldingClosureStress exposing (main)

{-| Put a partial-applied closure with heap captures into an MVar, force
    multiple minor GCs, take the closure back, and apply it. Verifies
    that the closure's unboxed bitmap and captured values survive the
    MVar scanner's encode→evacuate→decode cycle — a bitmap bug on a
    captured slot is precisely the failure shape surfaced in Stage 7.

    Closure: `\x y -> x + y + captured` with `captured = 100`, applied
    as `3 + 4 + 100 = 107`.
-}

-- CHECK: MVarHoldingClosureStress: True

import Bytes.Decode as BD
import Bytes.Encode as BE
import Eco.MVar as MV
import StressHarness exposing (StressFlags)
import Task


makeAdder : Int -> (Int -> Int -> Int)
makeAdder captured =
    \x y -> x + y + captured


fnEnc : (Int -> Int -> Int) -> BE.Encoder
fnEnc _ =
    BE.unsignedInt8 0


fnDec : BD.Decoder (Int -> Int -> Int)
fnDec =
    BD.succeed (\_ _ -> 0)


heavyAlloc : Int -> Task.Task Never Int
heavyAlloc size =
    Task.succeed (List.sum (List.range 1 size))


singleCycle : Int -> Task.Task Never Bool
singleCycle size =
    let
        f =
            makeAdder 100
    in
    MV.new
        |> Task.andThen
            (\mv ->
                MV.put fnEnc mv f
                    |> Task.andThen (\_ -> heavyAlloc size)
                    |> Task.andThen (\_ -> heavyAlloc size)
                    |> Task.andThen (\_ -> heavyAlloc size)
                    |> Task.andThen (\_ -> MV.take fnDec mv)
            )
        |> Task.map (\g -> g 3 4 == 107)


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        loopCount =
            flags.numLoops // 100
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> singleCycle flags.maxSize)


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "MVarHoldingClosureStress"
        , run = run
        }
