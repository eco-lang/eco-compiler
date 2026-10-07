module SimpleProgramFreeMsgTest exposing (main)

{-| `main : System.SimpleProgram msg`, with the message type left free, as gren
programs usually write it (plans/eco-system-library.md Phase 3 step 3.6).
-}

-- CHECK: free msg ok
-- EXIT: 0

import Stream.Log
import System


main : System.SimpleProgram msg
main =
    System.defineSimpleProgram
        (\env -> System.endSimpleProgram (Stream.Log.line env.stdout "free msg ok"))
