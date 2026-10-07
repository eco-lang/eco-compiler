module StderrTest exposing (main)

{-| `env.stderr` writes to fd 2 (plans/eco-system-library.md Phase 3 step 3.6).
Both stdout and stderr reach the harness's output pipe; only stderr is used here.
-}

-- CHECK: to stderr: 42
-- EXIT: 0

import Stream
import System
import Task


main : System.SimpleProgram ()
main =
    System.defineSimpleProgram
        (\env ->
            System.endSimpleProgram
                (Stream.writeLineAsBytes ("to stderr: " ++ String.fromInt 42) env.stderr
                    |> Task.map (\_ -> ())
                    |> Task.onError (\_ -> Task.succeed ())
                )
        )
