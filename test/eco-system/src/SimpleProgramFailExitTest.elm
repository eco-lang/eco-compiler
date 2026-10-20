module SimpleProgramFailExitTest exposing (main)

{-| A simple program whose task fails ends with exit status 1, after the output it wrote before
failing has been written.
-}

-- CHECK: before failing
-- EXIT: 1

import Stream
import System
import Task


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram
        (\env ->
            Stream.logLine "before failing" env.stdout
                |> Task.andThen (\_ -> Task.fail "boom")
        )
