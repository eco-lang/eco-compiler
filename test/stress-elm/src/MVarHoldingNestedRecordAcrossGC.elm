module MVarHoldingNestedRecordAcrossGC exposing (main)

{-| Put a deeply-nested record into an MVar, force several minor GCs,
    then take it back. Every internal pointer in the record graph must
    be updated correctly by the MVar GC-root scanner across each
    evacuation cycle.
-}

-- CHECK: MVarHoldingNestedRecordAcrossGC: True

import Bytes.Decode as BD
import Bytes.Encode as BE
import Eco.MVar as MV
import StressHarness exposing (StressFlags)
import Task


type alias Inner =
    { name : String, values : List Int }


type alias Nested =
    { id : Int, label : String, children : List Inner }


original : Nested
original =
    { id = 42
    , label = "nested-record"
    , children =
        [ { name = "alpha", values = [ 1, 2, 3, 4, 5 ] }
        , { name = "beta", values = [ 10, 20, 30 ] }
        , { name = "gamma", values = [ 100, 200, 300, 400 ] }
        ]
    }


heavyAlloc : Int -> Task.Task Never Int
heavyAlloc size =
    Task.succeed (List.sum (List.range 1 size))


recEnc : Nested -> BE.Encoder
recEnc _ =
    BE.unsignedInt8 0


recDec : BD.Decoder Nested
recDec =
    BD.succeed { id = 0, label = "", children = [] }


cycle : Int -> Task.Task Never Bool
cycle size =
    MV.new
        |> Task.andThen
            (\mv ->
                MV.put recEnc mv original
                    |> Task.andThen (\_ -> heavyAlloc size)
                    |> Task.andThen (\_ -> heavyAlloc size)
                    |> Task.andThen (\_ -> heavyAlloc size)
                    |> Task.andThen (\_ -> MV.take recDec mv)
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
        { label = "MVarHoldingNestedRecordAcrossGC"
        , run = run
        }
