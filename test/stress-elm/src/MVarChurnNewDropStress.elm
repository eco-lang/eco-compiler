module MVarChurnNewDropStress exposing (main)

{-| Tight loop of `new` + `put` + `drop` many thousand times, interleaved
    with `put`/`take` on a persistent MVar so GCs fire throughout.
    Detects leaked slot IDs, stale table entries, and drop-vs-scanner
    interaction bugs.

    At the end, the persistent MVar must still hold its expected value.
-}

-- CHECK: MVarChurnNewDropStress: True

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


{-| Builds a throwaway list to churn nursery memory on each churn iter. -}
smallAlloc : Int -> Task.Task Never Int
smallAlloc size =
    Task.succeed (List.sum (List.range 1 size))


churn : Int -> MV.MVar Int -> Int -> Task.Task Never ()
churn size persistent i =
    if i <= 0 then
        Task.succeed ()

    else
        MV.new
            |> Task.andThen
                (\mv ->
                    MV.put intEnc mv i
                        |> Task.andThen (\_ -> MV.drop mv)
                        |> Task.andThen (\_ -> smallAlloc size)
                        |> Task.andThen
                            (\_ ->
                                if modBy 16 i == 0 then
                                    MV.take intDec persistent
                                        |> Task.andThen
                                            (\v ->
                                                MV.put intEnc persistent (v + 1)
                                                    |> Task.andThen (\_ -> churn size persistent (i - 1))
                                            )

                                else
                                    churn size persistent (i - 1)
                            )
                )


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
            (\persistent ->
                MV.put intEnc persistent 0
                    |> Task.andThen (\_ -> churn size persistent count)
                    |> Task.andThen (\_ -> MV.take intDec persistent)
            )
        |> Task.map (\final -> final == count // 16)


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "MVarChurnNewDropStress"
        , run = run
        }
