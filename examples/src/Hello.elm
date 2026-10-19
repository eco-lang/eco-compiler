module Hello exposing (main)

{-| Hello world: print a greeting to stdout.

    eco make src/Hello.elm --output=hello && ./hello

-}

import Stream
import System


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram
        (\env -> Stream.logLine "Hello World!" env.stdout)
