module TailRecurseCallback exposing (main)

-- CHECK: TailRecurseCallback: True

import StressHarness exposing (StressFlags)
import Task


loop : (Int -> Int) -> Int -> Int -> Int
loop f count acc =
    if count <= 0 then
        acc

    else
        loop f (count - 1) (f acc)


increment : Int -> Int
increment x =
    x + 1


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        size =
            flags.maxSize
    in
    StressHarness.loopWhile flags
        flags.numLoops
        (\_ -> Task.succeed (loop increment size 0 == size))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "TailRecurseCallback"
        , run = run
        }
