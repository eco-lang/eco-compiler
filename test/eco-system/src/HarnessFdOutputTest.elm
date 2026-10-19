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

import Stream
import System
import Task


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram
        (\env ->
            Stream.logLine "raw stdout line" env.stdout
                |> Task.andThen (\_ -> Stream.logLine "raw stderr line" env.stderr)
        )
