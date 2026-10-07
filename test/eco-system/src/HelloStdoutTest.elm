module HelloStdoutTest exposing (main)

{-| The README hello world (plans/eco-system-library.md Phase 3 step 3.6):
`Stream.Log.line env.stdout` writes to the program's real stdout (fd 1).
-}

-- CHECK: Hello, eco/system!
-- EXIT: 0

import Stream.Log
import System


main : System.SimpleProgram ()
main =
    System.defineSimpleProgram
        (\env ->
            System.endSimpleProgram
                (Stream.Log.line env.stdout "Hello, eco/system!")
        )
