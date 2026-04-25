module TailRecurse exposing (main)

-- CHECK: TailRecurse: True

import StressHarness exposing (StressFlags)
import Task


loop : Int -> Int -> Int
loop count acc =
    if count <= 0 then
        acc

    else
        loop (count - 1) (acc + 1)


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        size =
            flags.maxSize
    in
    StressHarness.loopWhile flags
        flags.numLoops
        (\_ -> Task.succeed (loop size 0 == size))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "TailRecurse"
        , run = run
        }
