module EcoSystemStreamReadUntilClosed exposing (main)

{-| Stress variant of eco-system/StreamReadUntilClosedTest
(plans/eco-system-library.md Phase 3 step 3.6, §3.3.3 gate 3).

Each cycle (a) folds `20 * maxSize` Ints written by a spawned writer through
identity(1,1) — one parked read or write per chunk — and (b) rebuilds a list of
`10 * maxSize` strings from `Stream.fromList` (all values buffered in the stream
table at once) with `readUntilClosed`.
-}

-- CHECK: EcoSystemStreamReadUntilClosed: True

import Process
import Stream
import StressHarness exposing (StressFlags)
import Task exposing (Task)


writeFrom : Int -> Int -> Stream.Writable Int -> Task Stream.Error ()
writeFrom i n w =
    if i > n then
        Stream.closeWritable w

    else
        Stream.write i w |> Task.andThen (writeFrom (i + 1) n)


sumThroughStream : Int -> Task Stream.Error Int
sumThroughStream n =
    Stream.identityTransformation
        |> Task.andThen
            (\t ->
                Process.spawn (writeFrom 1 n (Stream.writable t) |> Task.onError (\_ -> Task.succeed ()))
                    |> Task.andThen (\_ -> Stream.readUntilClosed (\v acc -> Ok (acc + v)) 0 (Stream.readable t))
            )


stringsThroughList : List String -> Task Stream.Error (List String)
stringsThroughList strings =
    Stream.fromList strings
        |> Task.andThen (Stream.readUntilClosed (\v acc -> Ok (v :: acc)) [])
        |> Task.map List.reverse


cycle : Int -> Int -> Task Never Bool
cycle size i =
    let
        n =
            20 * size

        strings =
            List.map (\k -> String.repeat (modBy 5 k + 1) (String.fromInt (k + i))) (List.range 1 (10 * size))
    in
    Task.map2 (\sum got -> sum == n * (n + 1) // 2 && got == strings)
        (sumThroughStream n)
        (stringsThroughList strings)
        |> Task.onError (\_ -> Task.succeed False)


run : StressFlags -> Task Never Bool
run flags =
    StressHarness.loopWhile flags (max 1 flags.numLoops) (cycle (max 1 flags.maxSize))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "EcoSystemStreamReadUntilClosed"
        , run = run
        }
