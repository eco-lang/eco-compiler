module SystemExitTaskAfterWriteTest exposing (main)

{-| Output whose write has succeeded is on stdout and stderr when `System.exitWithCodeTask` ends
the program at once, in the order it was written; the eco compiler relies on this
(plans/compiler-io-on-eco-system.md P1.2, §6.5).
-}

-- CHECK: line 1
-- CHECK: line 50000
-- CHECK: done
-- EXIT: 3

import Stream
import System
import Task


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram
        (\env ->
            List.range 1 50000
                |> List.map (\i -> "line " ++ String.fromInt i)
                |> String.join "\n"
                |> (\text -> Stream.writeLine text env.stdout)
                |> Task.andThen (\_ -> Stream.writeLine "done" env.stderr)
                |> Task.andThen (\_ -> System.exitWithCodeTask 3)
        )
