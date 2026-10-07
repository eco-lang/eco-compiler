module EcoSystemStreamBackpressure exposing (main)

{-| Stress variant of eco-system/StreamBackpressureTest
(plans/eco-system-library.md Phase 3 step 3.6, §3.3.3 gate 3).

Two spawned writers push `5 * maxSize` strings each through identity(1,1)
while one reader drains it. With capacity 1 nearly every write parks; the
second writer regularly finds the write lock held and retries after a yield
(`Locked`). Every value must arrive exactly once.
-}

-- CHECK: EcoSystemStreamBackpressure: True

import Process
import Stream
import StressHarness exposing (StressFlags)
import Task exposing (Task)


writeWithRetry : String -> Stream.Writable String -> Task Never ()
writeWithRetry value w =
    Stream.write value w
        |> Task.map (\_ -> ())
        |> Task.onError
            (\err ->
                case err of
                    Stream.Locked ->
                        Process.sleep 0 |> Task.andThen (\_ -> writeWithRetry value w)

                    _ ->
                        Task.succeed ()
            )


writer : String -> Int -> Int -> Stream.Writable String -> Task Never ()
writer prefix i n w =
    if i > n then
        Task.succeed ()

    else
        writeWithRetry (prefix ++ String.fromInt i) w
            |> Task.andThen (\_ -> writer prefix (i + 1) n w)


readN : Int -> Stream.Readable String -> List String -> Task Stream.Error (List String)
readN n r acc =
    if n <= 0 then
        Task.succeed acc

    else
        Stream.read r |> Task.andThen (\v -> readN (n - 1) r (v :: acc))


cycle : Int -> Int -> Task Never Bool
cycle perWriter _ =
    let
        expected =
            List.map (\k -> "a" ++ String.fromInt k) (List.range 1 perWriter)
                ++ List.map (\k -> "b" ++ String.fromInt k) (List.range 1 perWriter)
                |> List.sort
    in
    Stream.identityTransformation
        |> Task.andThen
            (\t ->
                Process.spawn (writer "a" 1 perWriter (Stream.writable t))
                    |> Task.andThen (\_ -> Process.spawn (writer "b" 1 perWriter (Stream.writable t)))
                    |> Task.andThen (\_ -> readN (2 * perWriter) (Stream.readable t) [])
            )
        |> Task.map (\got -> List.sort got == expected)
        |> Task.onError (\_ -> Task.succeed False)


run : StressFlags -> Task Never Bool
run flags =
    StressHarness.loopWhile flags (max 1 flags.numLoops) (cycle (5 * max 1 flags.maxSize))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "EcoSystemStreamBackpressure"
        , run = run
        }
