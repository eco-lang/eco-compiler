module HarnessStdinDevNullTest exposing (main)

{-| Harness self-test (Phase 1 step 8c, deferred to Phase 3): without a
`-- STDIN:` directive the program's stdin is /dev/null, so reading it ends at
once instead of hanging on the runner's terminal.
-}

-- CHECK: stdin chunks: 0
-- EXIT: 0

import Stream
import Stream.Log
import System
import Task


main : System.SimpleProgram ()
main =
    System.defineSimpleProgram
        (\env ->
            System.endSimpleProgram
                (Stream.readUntilClosed (\_ n -> Ok (n + 1)) 0 env.stdin
                    |> Task.map (\n -> "stdin chunks: " ++ String.fromInt n)
                    |> Task.onError (\err -> Task.succeed ("error: " ++ Stream.errorToString err))
                    |> Task.andThen (Stream.Log.line env.stdout)
                )
        )
