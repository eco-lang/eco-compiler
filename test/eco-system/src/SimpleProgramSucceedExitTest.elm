module SimpleProgramSucceedExitTest exposing (main)

{-| A simple program whose task succeeds ends with exit status 0.
-}

-- CHECK: succeeded
-- EXIT: 0

import Stream
import System


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram
        (\env -> Stream.logLine "succeeded" env.stdout)
