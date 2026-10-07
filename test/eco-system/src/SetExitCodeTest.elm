module SetExitCodeTest exposing (main)

{-| `System.setExitCode 4` sets the status the program ends with, but does not
end it: the writes that follow still complete (plans/eco-system-library.md
Phase 3 step 3.6, §3.7).
-}

-- CHECK: still running
-- CHECK: done writing
-- EXIT: 4

import Stream.Log
import System
import Task


main : System.SimpleProgram ()
main =
    System.defineSimpleProgram
        (\env ->
            System.endSimpleProgram
                (System.setExitCode 4
                    |> Task.andThen (\_ -> Stream.Log.line env.stdout "still running")
                    |> Task.andThen (\_ -> Stream.Log.line env.stderr "done writing")
                )
        )
