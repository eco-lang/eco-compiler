module HarnessExitNonZeroTest exposing (main)

{-| Harness self-test (plans/eco-system-library.md Phase 1 step 8b/c, deferred
to Phase 3): a non-zero `-- EXIT:` status is enforced, and output written to
the real stdout before `exitWithCode` is still checked.
-}

-- CHECK: exiting with 7
-- EXIT: 7

import Stream.Log
import System
import Task


main : System.Program () ()
main =
    System.defineProgram
        { init = \env -> ( (), Task.perform identity (Stream.Log.line env.stdout "exiting with 7") )
        , update = \_ model -> ( model, System.exitWithCode 7 )
        , subscriptions = \_ -> Sub.none
        }
