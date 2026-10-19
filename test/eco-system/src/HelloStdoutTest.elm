module HelloStdoutTest exposing (main)

{-| The README hello world (plans/eco-system-library.md Phase 3 step 3.6):
`Stream.logLine env.stdout` writes to the program's real stdout (fd 1).
-}

-- CHECK: Hello, eco/system!
-- EXIT: 0

import Stream
import System


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram
        (\env ->
            Stream.logLine "Hello, eco/system!" env.stdout
        )
