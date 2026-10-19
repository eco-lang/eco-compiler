module SetExitCodeTest exposing (main)

{-| `System.setExitCode 4` sets the status the program ends with, but does not
end it: the writes that follow still complete (plans/eco-system-library.md
Phase 3 step 3.6, §3.7).
-}

-- CHECK: still running
-- CHECK: done writing
-- EXIT: 4

import Stream
import System
import Task


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram
        (\env ->
            System.setExitCode 4
                |> Task.andThen (\_ -> Stream.logLine "still running" env.stdout)
                |> Task.andThen (\_ -> Stream.logLine "done writing" env.stderr)
        )
