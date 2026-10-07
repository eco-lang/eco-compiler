module EcoSystemProcessRun exposing (main)

{-| Stress variant of the eco-system Process run tests
(plans/eco-system-library.md Phase 5 step 5.4, §3.3.3 gate 3).

Each cycle runs `n` children concurrently (one Elm process each), every one
writing a different amount of output and exiting with its own code, plus a
`maximumBytesWrittenToStreams` overflow and a `runDuration` kill. Every
outcome is checked and logged into an identity stream, which the cycle then
reads back. Exercises the WaitService lane, the run collectors, the
runDuration timer (fired and cancelled), Bytes results under GC, and the
exactly-once pendingAsync release (a leak would keep the program alive).
-}

-- CHECK: EcoSystemProcessRun: True

import Bytes
import Process
import Stream
import StressHarness exposing (StressFlags)
import System.Process as P
import Task exposing (Task)


noShell : P.RunOptions
noShell =
    let
        d =
            P.defaultRunOptions
    in
    { d | shell = P.NoShell }


expectExit : Int -> Int -> Task P.FailedRun P.SuccessfulRun -> Task Never Bool
expectExit code width task =
    task
        |> Task.map (\r -> code == 0 && Bytes.width r.stdout == width && Bytes.width r.stderr == 0)
        |> Task.onError
            (\err ->
                Task.succeed <|
                    case err of
                        P.ProgramError e ->
                            e.exitCode == code && Bytes.width e.stdout == width

                        P.InitError _ ->
                            False
            )


oneRun : Int -> Int -> Task Never Bool
oneRun cycleIndex k =
    let
        width =
            k * 37 + modBy 11 cycleIndex

        code =
            modBy 5 k
    in
    expectExit code
        width
        (P.run "sh"
            [ "-c", "head -c " ++ String.fromInt width ++ " /dev/zero; exit " ++ String.fromInt code ]
            { noShell | runDuration = P.Milliseconds 60000 }
        )


overflow : Task Never Bool
overflow =
    expectExit -1 4096 (P.run "yes" [] { noShell | maximumBytesWrittenToStreams = 4096 })


timeout : Task Never Bool
timeout =
    expectExit -1 0 (P.run "sleep" [ "5" ] { noShell | runDuration = P.Milliseconds 30 })


cycle : Int -> Int -> Task Never Bool
cycle size i =
    let
        n =
            clamp 2 16 size

        jobs =
            overflow :: timeout :: List.map (oneRun i) (List.range 0 (n - 1))

        total =
            List.length jobs
    in
    Stream.identityTransformationWithOptions { readCapacity = 100, writeCapacity = 100 }
        |> Task.andThen
            (\log ->
                jobs
                    |> List.map
                        (\job ->
                            Process.spawn
                                (job
                                    |> Task.andThen
                                        (\ok ->
                                            Stream.enqueue ok (Stream.writable log)
                                                |> Task.map (\_ -> ())
                                                |> Task.onError (\_ -> Task.succeed ())
                                        )
                                )
                        )
                    |> Task.sequence
                    |> Task.andThen (\_ -> readN total (Stream.readable log) True)
            )
        |> Task.onError (\_ -> Task.succeed False)


readN : Int -> Stream.Readable Bool -> Bool -> Task Stream.Error Bool
readN remaining readable acc =
    if remaining <= 0 then
        Task.succeed acc

    else
        Stream.read readable
            |> Task.andThen (\ok -> readN (remaining - 1) readable (acc && ok))


run : StressFlags -> Task Never Bool
run flags =
    StressHarness.loopWhile flags (max 1 flags.numLoops) (cycle (max 1 flags.maxSize))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "EcoSystemProcessRun"
        , run = run
        }
