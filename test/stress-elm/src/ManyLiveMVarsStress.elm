module ManyLiveMVarsStress exposing (main)

{-| Create a large number of MVars each holding a distinct `Int`, force
    several GCs, then take from every one and verify the values match
    their expected keys. Stresses the scanner iterating the full
    `s_mvars` hashmap on every collection.
-}

-- CHECK: ManyLiveMVarsStress: True

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


heavyAlloc : Int -> Task.Task Never Int
heavyAlloc size =
    Task.succeed (List.sum (List.range 1 size))


{-| Make `total` MVars each pre-filled with its index `i` in [1..total]. -}
makeAll : Int -> Task.Task Never (List (MV.MVar Int))
makeAll total =
    let
        go : Int -> List (MV.MVar Int) -> Task.Task Never (List (MV.MVar Int))
        go i acc =
            if i > total then
                Task.succeed (List.reverse acc)

            else
                MV.new
                    |> Task.andThen
                        (\mv ->
                            MV.put intEnc mv i
                                |> Task.andThen (\_ -> go (i + 1) (mv :: acc))
                        )
    in
    go 1 []


takeAll : List (MV.MVar Int) -> Task.Task Never (List Int)
takeAll mvars =
    let
        go : List (MV.MVar Int) -> List Int -> Task.Task Never (List Int)
        go ms acc =
            case ms of
                [] ->
                    Task.succeed (List.reverse acc)

                mv :: rest ->
                    MV.take intDec mv
                        |> Task.andThen (\v -> go rest (v :: acc))
    in
    go mvars []


cycle : Int -> Int -> Task.Task Never Bool
cycle mvarCount allocSize =
    makeAll mvarCount
        |> Task.andThen
            (\mvars ->
                heavyAlloc allocSize
                    |> Task.andThen (\_ -> heavyAlloc allocSize)
                    |> Task.andThen (\_ -> heavyAlloc allocSize)
                    |> Task.andThen (\_ -> takeAll mvars)
            )
        |> Task.map (\vs -> vs == List.range 1 mvarCount)


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        loopCount =
            flags.numLoops // 100

        mvarCount =
            flags.maxSize // 2

        allocSize =
            flags.maxSize
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> cycle mvarCount allocSize)


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "ManyLiveMVarsStress"
        , run = run
        }
