module SystemExitTaskCodeTest exposing (main)

{-| `System.exitWithCodeTask 7`, run deep in a task chain, ends the program at once with status
7, and nothing after it runs (plans/compiler-io-on-eco-system.md P1.2).
-}

-- CHECK: before exit
-- CHECK-NOT: after exit
-- EXIT: 7

import Stream
import System
import Task


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram
        (\env ->
            Stream.writeLine "before exit" env.stdout
                |> Task.andThen (\_ -> System.exitWithCodeTask 7)
                |> Task.andThen (\_ -> Stream.writeLine "after exit" env.stdout)
        )
