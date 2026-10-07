module HarnessFdOutputTest exposing (main)

{-| Harness self-test (Phase 1 step 8b, deferred to Phase 3): in this suite the
CHECK and CHECK-NOT patterns are matched against the program's raw fd 1 and
fd 2 output, not only the eco-thread `Debug.log` capture. Nothing here uses
`Debug.log`.
-}

-- CHECK: raw stdout line
-- CHECK: raw stderr line
-- CHECK-NOT: never written
-- EXIT: 0

import Stream.Log
import System
import Task


main : System.SimpleProgram ()
main =
    System.defineSimpleProgram
        (\env ->
            System.endSimpleProgram
                (Stream.Log.line env.stdout "raw stdout line"
                    |> Task.andThen (\_ -> Stream.Log.line env.stderr "raw stderr line")
                )
        )
