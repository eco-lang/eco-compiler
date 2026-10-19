module HarnessExitNonZeroTest exposing (main)

{-| Harness self-test (plans/eco-system-library.md Phase 1 step 8b/c, deferred
to Phase 3): a non-zero `-- EXIT:` status is enforced, and output written to
the real stdout before `exitWithCode` is still checked.
-}

-- CHECK: exiting with 7
-- EXIT: 7

import Stream
import System
import Task


main : Platform.Program System.Environment () ()
main =
    Platform.worker
        { init = \env -> ( (), Task.perform identity (Stream.logLine "exiting with 7" env.stdout) )
        , update = \_ model -> ( model, System.exitWithCode 7 )
        , subscriptions = \_ -> Sub.none
        }
