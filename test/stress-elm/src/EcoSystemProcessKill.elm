module EcoSystemProcessKill exposing (main)

{-| Stress test for killing `run` tasks (plans/eco-system-library.md Phase 5,
§3.3.2 T7, §3.3.3 gate 3).

Each cycle starts `n` long `run`s in their own Elm processes, kills every one
of them with `Process.kill` (the T7 kill handle SIGTERMs the child; the
killed task never resumes, and the child's exit still releases its
pendingAsync count exactly once), and checks that a fresh `run` still works.
A leaked count would keep the program from exiting; a double release would
let it exit early.
-}

-- CHECK: EcoSystemProcessKill: True

import Bytes
import Process
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


cycle : Int -> Int -> Task Never Bool
cycle size _ =
    let
        n =
            clamp 2 12 size
    in
    List.repeat n
        (Process.spawn (P.run "sleep" [ "30" ] noShell |> Task.map (\_ -> ()) |> Task.onError (\_ -> Task.succeed ())))
        |> Task.sequence
        |> Task.andThen
            (\pids ->
                Process.sleep 5
                    |> Task.andThen (\_ -> Task.sequence (List.map Process.kill pids))
            )
        |> Task.andThen (\_ -> P.run "printf" [ "alive" ] noShell)
        |> Task.map (\r -> Bytes.width r.stdout == 5)
        |> Task.onError (\_ -> Task.succeed False)


run : StressFlags -> Task Never Bool
run flags =
    StressHarness.loopWhile flags (max 1 flags.numLoops) (cycle (max 1 flags.maxSize))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "EcoSystemProcessKill"
        , run = run
        }
