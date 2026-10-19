module SimpleProgramFreeMsgTest exposing (main)

{-| `main : Platform.Program System.Environment () ()`, with the message type left free, as gren
programs usually write it (plans/eco-system-library.md Phase 3 step 3.6).
-}

-- CHECK: free msg ok
-- EXIT: 0

import Stream
import System


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram
        (\env -> Stream.logLine "free msg ok" env.stdout)
