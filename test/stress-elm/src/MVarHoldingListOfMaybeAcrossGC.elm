module MVarHoldingListOfMaybeAcrossGC exposing (main)

{-| Put a `List (Maybe Record)` — interleaved embedded-constant `Nothing`s
    and heap-allocated `Just` records — into an MVar, force several
    minor GCs, then take it back. Heterogeneous pointer-vs-constant slot
    values flow through the scanner's encode→evacuate→decode path on
    every collection.
-}

-- CHECK: MVarHoldingListOfMaybeAcrossGC: True

import Bytes.Decode as BD
import Bytes.Encode as BE
import Eco.MVar as MV
import StressHarness exposing (StressFlags)
import Task


type alias Item =
    { tag : Int, label : String }


original : List (Maybe Item)
original =
    [ Just { tag = 1, label = "a" }
    , Nothing
    , Just { tag = 2, label = "b" }
    , Nothing
    , Nothing
    , Just { tag = 3, label = "c" }
    , Just { tag = 4, label = "d" }
    , Nothing
    ]


heavyAlloc : Int -> Task.Task Never Int
heavyAlloc size =
    Task.succeed (List.sum (List.range 1 size))


valEnc : List (Maybe Item) -> BE.Encoder
valEnc _ =
    BE.unsignedInt8 0


valDec : BD.Decoder (List (Maybe Item))
valDec =
    BD.succeed []


cycle : Int -> Task.Task Never Bool
cycle size =
    MV.new
        |> Task.andThen
            (\mv ->
                MV.put valEnc mv original
                    |> Task.andThen (\_ -> heavyAlloc size)
                    |> Task.andThen (\_ -> heavyAlloc size)
                    |> Task.andThen (\_ -> heavyAlloc size)
                    |> Task.andThen (\_ -> MV.take valDec mv)
            )
        |> Task.map (\v -> v == original)


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
        { label = "MVarHoldingListOfMaybeAcrossGC"
        , run = run
        }
